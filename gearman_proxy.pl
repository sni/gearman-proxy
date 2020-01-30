#!/usr/bin/perl
# vim: expandtab:ts=4:sw=4:syntax=perl

=pod

=head1 NAME

gearman_proxy - proxy for gearman jobs

=head1 SYNOPSIS

gearman_proxy [options]

Options:

    'c|config'      defines the config file
    'l|log'         defines the logfile
    'd|debug'       enable debug output
    'h'             this help message

=head1 DESCRIPTION

This script redirects jobs from one gearmand server to another gearmand server.

=head1 OPTIONS

=item [B<--config> I<path>]

Specifies the path to the configfile / folder.

=item [B<--log> I<path>]

Specifies the path to the logfile.

=item [B<--debug>]

Enable debug logging.

=head1 EXAMPLES

    %> ./gearman_proxy.pl --config=gearman_proxy.cfg

=cut

use warnings;
use strict;
use Pod::Usage;
use Getopt::Long;

our $VERSION = "2.0";

my $config = {
    pidFile     => "",
    logFile     => "",
    debug       => 0,
    configFiles => [],
};
GetOptions ('p|pid=s'    => \$config->{'pidFile'},
            'l|log=s'    => \$config->{'logFile'},
            'c|config=s' => \@{$config->{'configFiles'}},
            'd|debug'    => \$config->{'debug'},
            'h'          => sub { pod2usage(); exit(3); },
            'v|version'  => sub { printf("%s - version %s\n", $0, $VERSION); exit(3); },
);

# use default config files
if(scalar @{$config->{'configFiles'}} == 0) {
    for my $file ('~/.gearman_proxy', '/etc/mod-gearman/gearman_proxy.cfg') {
        push @{$config->{'configFiles'}}, $file if -r $file;
    }
    if(defined $ENV{OMD_ROOT}) {
        my $file = $ENV{OMD_ROOT}.'/etc/mod-gearman/proxy.cfg';
        push @{$config->{'configFiles'}}, $file if -r $file;
    }
}

exit(GearmanProxy->run($config));


#################################################
package GearmanProxy;

use warnings;
use strict;
use Gearman::Worker;
use Gearman::Client;
use threads;
use Data::Dumper;
use Socket qw(IPPROTO_TCP SOL_SOCKET SO_KEEPALIVE TCP_KEEPIDLE TCP_KEEPINTVL TCP_KEEPCNT);
use POSIX ();
use Time::HiRes q/gettimeofday/;
use sigtrap 'handler', \&_signal_handler, 'HUP', 'TERM';

my $logFile;
my $pidFile;
my $debug_log_enabled;

#################################################
sub run {
    my($class, $config) = @_;

    my $self = {
        args  => $config,
        debug => $config->{'debug'},
    };
    bless $self, $class;
    $pidFile           = $self->{'args'}->{'pidFile'};
    $debug_log_enabled = $self->{'args'}->{'debug'};

    _info(sprintf("%s v%s starting...", $0, $VERSION));
    _debug('command line arguments:');
    _debug($self->{'args'});

    #################################################
    # save pid file
    if($pidFile) {
        open(my $fhpid, ">", $pidFile) or die "open ".$pidFile." failed: ".$!;
        print $fhpid $$;
        close($fhpid);
    }

    while(1) {
        $self->_work();
    }

    return(0);
}

#################################################
END {
    unlink($pidFile) if $pidFile;
};

#################################################
sub _signal_handler {
    my($sig) = @_;
    for my $thr (threads->list()) {
        $thr->kill($sig)->detach();
    }
    if($sig eq 'TERM') {
        _info(sprintf("caught signal %s, exiting...", $sig));
        exit(0);
    }
    _info(sprintf("caught signal %s, reloading configuration", $sig));
}

#################################################
sub _work {
    my($self) = @_;

    $self->_read_config($self->{'args'}->{'configFiles'});
    _debug($self->{'queues'});

    if(!defined $self->{'queues'} or scalar keys %{$self->{'queues'}} == 0) {
        _warn('no queues configured');
    }

    #################################################
    # create worker
    my $workers = {};
    for my $conf (keys %{$self->{'queues'}}) {
        my($server,$queue) = split/\//, $conf, 2;
        $workers->{$server} = [] unless defined $workers->{$server};
        push @{$workers->{$server}}, { from => $queue, to => $self->{'queues'}->{$conf} };
    }

    # cache client connections
    $self->{'clients'} = {};

    # start all worker
    for my $server (keys %{$workers}) {
        threads->create('_worker', $self, $server, $workers->{$server});
    }

    # wait till worker finish
    while(scalar threads->list() > 0) {
        sleep(5);
    }
    _debug("all worker finished");
}

#################################################
sub _worker {
    my($self, $server, $queues) = @_;
    my $tid = threads->tid();
    _debug(sprintf("[%s] worker thread started", $tid));

    $SIG{'HUP'}  = sub {
        _debug(sprintf("[%s] worker thread exits by signal %s", $tid, "HUP"));
        threads->exit();
    };

    while(1) {
        my $worker = Gearman::Worker->new(job_servers => [ $server ]);
        for my $queue (@{$queues}) {
            $worker->register_function($queue->{'from'} => sub { $self->_forward_job($queue->{'to'}, @_) } );
        }

        _enable_tcp_keepalive($worker);

        $worker->work(
            on_start => sub {
                my ($jobhandle) = @_;
                _debug(sprintf("[%s][%s] job starting", $tid, $jobhandle));
            },
            on_complete => sub {
                my ($jobhandle, $result) = @_;
                _debug(sprintf("[%s][%s] job completed", $tid, $jobhandle));
            },
            on_fail => sub {
                my($jobhandle, $err) = @_;
                _error(sprintf("[%s][%s] job failed", $tid, $jobhandle));
            },
            stop_if => sub {
                my ($is_idle, $last_job_time) = @_;
                #return $is_idle;
                _debug(sprintf("[%s] stop_if: is_idle=%d - last_job_time=%s", $tid, $is_idle, $last_job_time ? $last_job_time : "never"));
                return;
            },
        );
    }
    return;
}

#################################################
sub _forward_job {
    my($self, $target,$job) = @_;
    my($server,$queue) = split/\//, $target, 2;

    _debug($job->handle." -> ".$target);

    my $client = $self->{'clients'}->{$server};
    unless( defined $client) {
        $client = Gearman::Client->new(job_servers => [ $server ]);
        $self->{'clients'}->{$server} = $client;
        _enable_tcp_keepalive($client);
    }

    $client->dispatch_background($queue, $job->arg, { uniq => $job->handle });
    return;
}

#################################################
sub _enable_tcp_keepalive {
    my($gearman_obj) = @_;

    # set tcp keepalive for our worker
    if($gearman_obj->{'sock_cache'}) {
        for my $sock (values %{$gearman_obj->{'sock_cache'}}) {
            setsockopt($sock, SOL_SOCKET,  SO_KEEPALIVE,   1);
            setsockopt($sock, IPPROTO_TCP, TCP_KEEPIDLE,  10); # The time (in seconds) the connection needs to remain idle before TCP starts sending keepalive probes
            setsockopt($sock, IPPROTO_TCP, TCP_KEEPINTVL,  5); # The time (in seconds) between individual keepalive probes.
            setsockopt($sock, IPPROTO_TCP, TCP_KEEPCNT,    3); # The maximum number of keepalive probes TCP should send before dropping the connection
        }
    } else {
        _warn("failed to set tcp keepalive");
    }
    return;
}

#################################################
sub _read_config {
    my($self, $files) = @_;

    # these variables can be overriden by the config files
    our $queues;
    our $logfile;
    our $debug;

    for my $entry (@{$files}) {
        my @files;
        if(-d $entry) {
            @files = glob($entry.'/*.{cfg,conf}');
        } else {
            @files = glob($entry);
        }
        for my $file (@files) {
            if(! -r $file) {
                _fatal("ERROR: cannot read: ".$file.": ".$!);
            }

            _debug("reading config file ".$file);
            do "$file";
        }
    }

    $self->{'logfile'} = $self->{'args'}->{'logFile'} // $logfile // 'stdout';
    $self->{'debug'}   = $self->{'args'}->{'debug'} // $debug // 0;
    $self->{'queues'}  = $queues;

    $debug_log_enabled = $self->{'debug'};
    $logFile           = $self->{'logfile'};
    return;
}

#################################################
sub _out {
    my($txt, $lvl) = @_;
    return unless defined $txt;
    $lvl = 'INFO' unless $lvl;
    if(ref $txt) {
        return(_out(Dumper($txt), $lvl));
    }

    my($fh, $close);
    if(!$logFile || lc($logFile) eq 'stdout' || $logFile eq '-') {
        $fh = *STDOUT;
    } elsif(lc($logFile) eq 'stderr') {
        $fh = *STDERR;
    } else {
        open($fh, ">>", $logFile) or die "open $logFile failed: ".$!;
        $close = 1;
    }

    chomp($txt);
    my @txt = split/\n/,$txt;
    my($seconds, $microseconds) = gettimeofday;
    for my $t (@txt)  {
        printf($fh "[%s.%s][%s] %s\n",
                    POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime($seconds)),
                    substr(sprintf("%06s", $microseconds), 0, 3), # zero pad microseconds to 6 digits and take the first 3 digits for milliseconds
                    $lvl,
                    $t,
        );
    }
    close($fh) if $close;

    return;
}

#################################################
sub _fatal {
    my($txt) = @_;
    _out($txt, "ERROR");
    exit(3);
}

#################################################
sub _warn {
    my($txt) = @_;
    _out($txt, "WARNING");
}

#################################################
sub _info {
    my($txt) = @_;
    _out($txt, "INFO");
}

#################################################
sub _debug {
    my($txt) = @_;
    return unless $debug_log_enabled;
    _out($txt, "DEBUG");
}