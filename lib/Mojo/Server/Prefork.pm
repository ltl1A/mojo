package Mojo::Server::Prefork;
use Mojo::Base 'Mojo::Server::Daemon';

use Fcntl ':flock';
use File::Spec::Functions qw(catfile tmpdir);
use IO::Poll 'POLLIN';
use List::Util 'shuffle';
use POSIX qw(setsid WNOHANG);
use Scalar::Util 'weaken';
use Time::HiRes 'ualarm';

has [qw(graceful_timeout heartbeat_timeout)] => 20;
has heartbeat_interval => 5;
has lock_file          => sub { catfile tmpdir, 'hypnotoad.lock' };
has lock_timeout       => 0.5;
has pid_file           => sub { catfile tmpdir, 'hypnotoad.pid' };
has workers            => 4;

sub DESTROY {
  my $self = shift;

  # Worker
  return unless $self->{finished};

  # Manager
  if (my $file = $self->{lock_file}) { unlink $file if -w $file }
  if (my $file = $self->{pid_file})  { unlink $file if -w $file }
}

sub daemonize {

  # Fork and kill parent
  die "Can't fork: $!" unless defined(my $pid = fork);
  exit 0 if $pid;
  setsid or die "Can't start a new session: $!";

  # Close file handles
  open STDIN,  '</dev/null';
  open STDOUT, '>/dev/null';
  open STDERR, '>&STDOUT';
}

sub run {
  my $self = shift;

  # No Windows support
  say 'Preforking not available for Windows.' and exit 0 if $^O eq 'MSWin32';

  # Preload application and start accepting connections
  $self->{lock_file} = $self->lock_file . ".$$";
  $self->start->app;

  # Pipe for worker communication
  pipe($self->{reader}, $self->{writer}) or die "Can't create pipe: $!";
  $self->{poll} = IO::Poll->new;
  $self->{poll}->mask($self->{reader}, POLLIN);

  # Clean manager environment
  local $SIG{INT} = local $SIG{TERM} = sub { $self->_term };
  local $SIG{CHLD} = sub {
    while ((my $pid = waitpid -1, WNOHANG) > 0) { $self->_reap($pid) }
  };
  local $SIG{QUIT} = sub { $self->_term(1) };
  local $SIG{TTIN} = sub { $self->workers($self->workers + 1) };
  local $SIG{TTOU} = sub {
    $self->workers($self->workers - 1) if $self->workers > 0;
    return unless $self->workers;
    $self->{pool}{shuffle keys %{$self->{pool}}}{graceful} ||= time;
  };

  # Mainloop
  $self->{running} = 1;
  $self->_manage while $self->{running};
}

sub _heartbeat {
  my $self = shift;

  # Poll for heartbeats
  my $poll = $self->{poll};
  $poll->poll(1);
  return unless $poll->handles(POLLIN);
  return unless $self->{reader}->sysread(my $chunk, 4194304);

  # Update heartbeats
  $self->{pool}{$1} and $self->emit(heartbeat => $1)->{pool}{$1}{time} = time
    while $chunk =~ /(\d+)\n/g;
}

sub _manage {
  my $self = shift;

  # Housekeeping
  if (!$self->{finished}) {

    # Spawn more workers
    $self->_spawn while keys %{$self->{pool}} < $self->workers;

    # Check PID file
    $self->_pid_file;
  }

  # Shutdown
  elsif (!keys %{$self->{pool}}) { return delete $self->{running} }

  # Manage workers
  $self->emit('manage')->_heartbeat;
  while (my ($pid, $w) = each %{$self->{pool}}) {

    # No heartbeat (graceful stop)
    my $interval = $self->heartbeat_interval;
    my $timeout  = $self->heartbeat_timeout;
    if (!$w->{graceful} && ($w->{time} + $interval + $timeout <= time)) {
      $self->app->log->info("Worker $pid has no heartbeat, restarting.");
      $w->{graceful} = time;
    }

    # Graceful stop with timeout
    $w->{graceful} ||= time if $self->{graceful};
    if ($w->{graceful}) {
      $self->app->log->debug("Trying to stop worker $pid gracefully.");
      kill 'QUIT', $pid;
      $w->{force} = 1 if $w->{graceful} + $self->graceful_timeout <= time;
    }

    # Normal stop
    if (($self->{finished} && !$self->{graceful}) || $w->{force}) {
      $self->app->log->debug("Stopping worker $pid.");
      kill 'KILL', $pid;
    }
  }
}

sub _pid_file {
  my $self = shift;

  # Don't need a PID file anymore
  return if $self->{finished};

  # Check if PID file already exists
  return if -e (my $file = $self->pid_file);

  # Create PID file
  $self->app->log->info(qq{Creating process id file "$file".});
  die qq{Can't create process id file "$file": $!}
    unless open my $pid, '>', $file;
  chmod 0644, $pid;
  print $pid $$;
}

sub _reap {
  my ($self, $pid) = @_;

  # CLean up dead worker
  $self->app->log->debug("Worker $pid stopped.")
    if delete $self->emit(reap => $pid)->{pool}{$pid};
}

sub _spawn {
  my $self = shift;

  # Manager
  die "Can't fork: $!" unless defined(my $pid = fork);
  return $self->emit(spawn => $pid)->{pool}{$pid} = {time => time} if $pid;

  # Prepare lock file
  my $file = $self->{lock_file};
  die qq{Can't open lock file "$file": $!} unless open my $lock, '>', $file;

  # Change user/group
  my $loop = $self->setuidgid->ioloop;

  # Accept mutex
  $loop->lock(
    sub {

      # Blocking
      my $l;
      if ($_[1]) {
        eval {
          local $SIG{ALRM} = sub { die "alarm\n" };
          my $old = ualarm $self->lock_timeout * 1000000;
          $l = flock $lock, LOCK_EX;
          ualarm $old;
        };
        if ($@) { $l = $@ eq "alarm\n" ? 0 : die($@) }
      }

      # Non blocking
      else { $l = flock $lock, LOCK_EX | LOCK_NB }

      return $l;
    }
  );
  $loop->unlock(sub { flock $lock, LOCK_UN });

  # Heartbeat messages (stop sending during graceful stop)
  weaken $self;
  $loop->recurring(
    $self->heartbeat_interval => sub {
      return unless shift->max_connections;
      $self->{writer}->syswrite("$$\n") or exit 0;
    }
  );

  # Clean worker environment
  $SIG{$_} = 'DEFAULT' for qw(INT TERM CHLD TTIN TTOU);
  $SIG{QUIT} = sub { $loop->max_connections(0) };
  delete $self->{$_} for qw(poll reader);

  # Start
  $self->app->log->debug("Worker $$ started.");
  $loop->start;
  exit 0;
}

sub _term {
  my ($self, $graceful) = @_;
  $self->emit(finish => $graceful)->{finished} = 1;
  $self->{graceful} = 1 if $graceful;
}

1;

=head1 NAME

Mojo::Server::Prefork - Preforking non-blocking I/O HTTP and WebSocket server

=head1 SYNOPSIS

  use Mojo::Server::Prefork;

  my $prefork = Mojo::Server::Prefork->new(listen => ['http://*:8080']);
  $prefork->unsubscribe('request');
  $prefork->on(request => sub {
    my ($prefork, $tx) = @_;

    # Request
    my $method = $tx->req->method;
    my $path   = $tx->req->url->path;

    # Response
    $tx->res->code(200);
    $tx->res->headers->content_type('text/plain');
    $tx->res->body("$method request for $path!");

    # Resume transaction
    $tx->resume;
  });
  $prefork->run;

=head1 DESCRIPTION

L<Mojo::Server::Hypnotoad> is a full featured, UNIX optimized, preforking
non-blocking I/O HTTP and WebSocket server, built around the very well tested
and reliable L<Mojo::Server::Daemon>, with C<IPv6>, C<TLS>, C<Comet> (long
polling) and multiple event loop support. Note that the server uses signals
for process management, so you should avoid modifying signal handlers in your
applications.

Optional modules L<EV> (4.0+), L<IO::Socket::IP> (0.16+) and
L<IO::Socket::SSL> (1.75+) are supported transparently through
L<Mojo::IOLoop>, and used if installed. Individual features can also be
disabled with the C<MOJO_NO_IPV6> and C<MOJO_NO_TLS> environment variables.

See L<Mojolicious::Guides::Cookbook> for more.

=head1 SIGNALS

L<Mojo::Server::Prefork> can be controlled at runtime with the following
signals.

=head2 Manager

=over 2

=item INT, TERM

Shutdown server immediately.

=item QUIT

Shutdown server gracefully.

=item TTIN

Increase worker pool by one.

=item TTOU

Decrease worker pool by one.

=back

=head2 Worker

=over 2

=item INT, TERM

Stop worker immediately.

=item QUIT

Stop worker gracefully.

=back

=head1 EVENTS

L<Mojo::Server::Prefork> inherits all events from L<Mojo::Server::Daemon> and
can emit the following new ones.

=head2 finish

  $prefork->on(finish => sub {
    my ($prefork, $graceful) = @_;
    ...
  });

Emitted when the server shuts down.

=head2 heartbeat

  $prefork->on(heartbeat => sub {
    my ($prefork, $pid) = @_;
    ...
  });

Emitted when a heartbeat message has been received from a worker.

=head2 manage

  $prefork->on(manage => sub {
    my ($prefork, $pid) = @_;
    ...
  });

Emitted when the server starts managing worker processes.

=head2 reap

  $prefork->on(reap => sub {
    my ($prefork, $pid) = @_;
    ...
  });

Emitted when a child process dies.

=head2 spawn

  $prefork->on(spawn => sub {
    my ($prefork, $pid) = @_;
    ...
  });

Emitted when a worker process is spawned.

=head1 ATTRIBUTES

L<Mojo::Server::Prefork> inherits all attributes from L<Mojo::Server::Daemon>
and implements the following new ones.

=head2 graceful_timeout

  my $timeout = $prefork->graceful_timeout;
  $prefork    = $prefork->graceful_timeout(15);

Maximum amount of time in seconds stopping a worker gracefully may take before
being forced, defaults to C<20>.

=head2 heartbeat_interval

  my $interval = $prefork->heartbeat_intrval;
  $prefork     = $prefork->heartbeat_interval(3);

Heartbeat interval in seconds, defaults to C<5>.

=head2 heartbeat_timeout

  my $timeout = $prefork->heartbeat_timeout;
  $prefork    = $prefork->heartbeat_timeout(2);

Maximum amount of time in seconds before a worker without a heartbeat will be
stopped gracefully, defaults to C<20>.

=head2 lock_file

  my $file = $prefork->lock_file;
  $prefork = $prefork->lock_file('/tmp/hypnotoad.lock');

Full path of accept mutex lock file prefix, to which the process id will be
appended, defaults to a random temporary path.

=head2 lock_timeout

  my $timeout = $prefork->lock_timeout;
  $prefork    = $prefork->lock_timeout(1);

Maximum amount of time in seconds a worker may block when waiting for the
accept mutex, defaults to C<0.5>.

=head2 pid_file

  my $file = $prefork->pid_file;
  $prefork = $prefork->pid_file('/tmp/hypnotoad.pid');

Full path of process id file, defaults to a random temporary path.

=head2 workers

  my $workers = $prefork->workers;
  $prefork    = $prefork->workers(10);

Number of worker processes, defaults to C<4>. A good rule of thumb is two
worker processes per CPU core.

=head1 METHODS

L<Mojo::Server::Prefork> inherits all methods from L<Mojo::Server::Daemon> and
implements the following new ones.

=head2 daemonize

  $prefork->daemonize;

Daemonize process.

=head2 run

  $prefork->run;

Run server.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
