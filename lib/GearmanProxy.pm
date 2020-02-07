package GearmanProxy;

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

=cut

use 5.008000;

use warnings;
use strict;
use Gearman::Worker;
use Gearman::Client;
use threads;
use threads::shared;
use Data::Dumper;
use Socket qw(IPPROTO_TCP SOL_SOCKET SO_KEEPALIVE TCP_KEEPIDLE TCP_KEEPINTVL TCP_KEEPCNT);
use POSIX ();
use File::Slurp qw/read_file/;
use Time::HiRes qw/gettimeofday/;
use sigtrap 'handler', \&_signal_handler, 'HUP', 'TERM';

our $VERSION = "2.0";

my $logFile;
my $pidFile;
my $debug_log_enabled;
my $max_retries     = 3;   # number of job retries
my $backlog_timeout = 600; # seconds until a job will be removed from the backlog
my %metrics_counter :shared;
my %metrics_bytes   :shared;
my %failed_clients  :shared;
my %backlog         :shared;

#################################################

=head2 new

    GearmanProxy->new({
        configFiles => list of config files
        logFile     => path to logfile or 'stderr', 'stdout'
        pidFile     => optional path to pidfile
        debug       => optional flag to enable debug output
    })

=cut
sub new {
    my($class, $config) = @_;

    my $self = {
        args  => $config,
        debug => $config->{'debug'},
    };
    bless $self, $class;

    return($self);
}

#################################################

=head2 run

    GearmanProxy->run()

=cut
sub run {
    my($self) = @_;

    $pidFile           = $self->{'args'}->{'pidFile'};
    $debug_log_enabled = $self->{'args'}->{'debug'};

    _debug('command line arguments:');
    _debug($self->{'args'});

    #################################################
    # save pid file
    if($pidFile) {
        open(my $fhpid, ">", $pidFile) || die "open ".$pidFile." failed: ".$!;
        print $fhpid $$;
        close($fhpid);
    }

    while(1) {
        $self->_work_loop();
    }

    return(0);
}

#################################################
END {
    unlink($pidFile) if $pidFile;
}

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
    return;
}

#################################################
sub _work_loop {
    my($self) = @_;

    $self->_read_config($self->{'args'}->{'configFiles'});
    _info(sprintf("%s v%s starting...", $0, $VERSION));
    _debug($self->{'queues'});

    if(!defined $self->{'queues'} || scalar keys %{$self->{'queues'}} == 0) {
        _error('no queues configured, exiting');
        exit(3);
    }

    # clear client connection cache and ciphers
    $self->_reset_counter_and_caches();

    # create one worker per uniq server
    for my $server (keys %{$self->{'queues'}}) {
        threads->create('_forward_worker', $self, $server, $self->{'queues'}->{$server});
    }

    # create backlog worker thread
    threads->create('_backlog_worker', $self);

    # create status worker thread
    if($self->{'statusqueue'}) {
        threads->create('_status_worker', $self);
    }

    # wait till worker finish
    while(scalar threads->list() > 0) {
        sleep(5);
    }
    _debug("all worker finished");
    return;
}

#################################################
sub _forward_worker {
    my($self, $server, $queues) = @_;
    _debug("worker thread started");

    my $keep_running = 1;
    while($keep_running) {
        my $worker = Gearman::Worker->new(job_servers => [ $server ]);
        _debug(sprintf("worker created for %s", $server));
        my $errors = 0;
        for my $queue (sort keys %{$queues}) {
            if(!$worker->register_function($queue => sub { $self->_job_handler($queues->{$queue}, @_) } )) {
                _warn(sprintf("register queue failed on %s for queue %s", $server, $queue));
                $errors++;
            }
        }

        if(scalar keys %{$queues} == $errors) {
            _error(sprintf("gearman daemon %s seems to be down", $server));
        }

        $keep_running = $self->_worker_work($worker);
    }
    return(threads->exit());
}

#################################################
sub _status_worker {
    my($self) = @_;
    _debug("status worker thread started");

    my $keep_running = 1;
    my($server, $queue) = split(/\//mx, $self->{'statusqueue'});
    while($keep_running) {
        my $worker = Gearman::Worker->new(job_servers => [ $server ]);
        _debug(sprintf("worker created for %s", $server));
        my $errors = 0;
        if(!$worker->register_function($queue => sub { $self->_status_handler($queue, @_) } )) {
            _warn(sprintf("register status queue failed on %s for queue %s", $server, $queue));
            $errors++;
        }

        if($errors) {
            _error(sprintf("gearman daemon %s seems to be down", $server));
        }

        $keep_running = $self->_worker_work($worker);
    }
    return(threads->exit());
}

#################################################
sub _job_handler {
    my($self, $config, $job) = @_;

    my $remoteHost = $config->{'remoteHost'};
    _debug(sprintf('job: %s -> server: %s - queue: %s', $job->handle, $remoteHost, $config->{'remoteQueue'}));
    _debug($config);

    my $data    = $job->arg;
    my $size_in = length($data);

    if($config->{'decrypt'}) {
        # decrypt data with local password
        $data = $self->_decrypt($data, $config->{'decrypt'});
    }
    # run data callback
    if($config->{'data_callback'}) {
        # if not already decrypted, data is still base64 encoded
        if(!$config->{'decrypt'}) {
            $data = MIME::Base64::decode_base64($data);
        }

        $data = &{$config->{'data_callback'}}($data, $job, $config, $self);

        # if data is not going to be encrypted, it needs to be base64
        if(!$config->{'encrypt'}) {
            $data = MIME::Base64::encode_base64($data);
        }
    }
    if($config->{'encrypt'}) {
        # encrypt data with new remote password
        $data = $self->_encrypt($data, $config->{'encrypt'});
    }
    my $size_out = length($data);

    # set metrics
    $metrics_counter{$config->{'localQueue'}.'::jobs'}++;
    $metrics_counter{'total_jobs'}++;

    $metrics_bytes{'bytes_in'}  += $size_in;
    $metrics_bytes{'bytes_out'} += $size_out;
    $metrics_bytes{$config->{'localQueue'}.'::bytes_out'} += $size_out;

    # forward data to remote server
    $self->_dispatch_task($remoteHost, $config->{'remoteQueue'}, $data, $job->handle);

    return(1);
}

#################################################
sub _status_handler {
    my($self, $config, $job) = @_;

    _debug(sprintf('job: %s -> status request', $job->handle));
    _debug($config);

    # make sure we always have some basic metrics set
    $metrics_counter{'total_jobs'}   += 0;
    $metrics_bytes{'bytes_in'}       += 0;
    $metrics_bytes{'bytes_out'}      += 0;
    $metrics_counter{'total_errors'} += 0;

    # count queues
    my $queue_nr = 0;
    for my $server (sort keys %{$self->{'queues'}}) {
        for my $queue (sort keys %{$self->{'queues'}->{$server}}) {
            my $queue_name = $self->{'queues'}->{$server}->{$queue}->{'localQueue'};
            if($queue_name) {
                $queue_nr++;
                $metrics_counter{$queue_name.'::jobs'} += 0;
                $metrics_bytes{$queue_name.'::bytes_out'}    += 0;
            }
        }
    }
    my $perfdata = sprintf("server=%d queues=%d", scalar keys %{$self->{'queues'}}, $queue_nr);

    my $merged = {%metrics_counter, %metrics_bytes};
    my $keys = [sort keys %{$merged}];
    # move those with :: at the end
    $keys = [grep(!/::/mx, @{$keys}), grep(/::/mx, @{$keys})];
    for my $key (@{$keys}) {
        if($metrics_counter{$key}) {
            $perfdata .= sprintf(" '%s'=%dc;;;", $key, $metrics_counter{$key});
        }
        if($metrics_bytes{$key}) {
            $perfdata .= sprintf(" '%s'=%db;;;", $key, $metrics_bytes{$key});
        }
    }

    my($exit, $additional_info, $backlog_nr) = (0, "", 0);
    {
        lock(%backlog);
        $backlog_nr = _count_sub_elements(\%backlog);
    }
    my $failed_nr  = scalar keys %failed_clients;
    if($failed_nr > 0) {
        $additional_info = sprintf(" %d server%s failed: %s.",
                            $failed_nr,
                            $failed_nr != 1 ? "s" : "",
                            join(", ", sort keys %failed_clients),
                        );
        $exit = 1;
    }
    if($backlog_nr > 0) {
        $additional_info .= sprintf(" backlog contains %d jobs.", $backlog_nr);
        $exit = 1;
        $perfdata .= sprintf(" 'backlog'=%d;;;", $backlog_nr);
    }

    return(sprintf("%d:%s - proxy version v%s running.%s|%s",
                $exit,
                _status_name($exit),
                $VERSION,
                $additional_info,
                $perfdata,
    ));
}

#################################################
sub _dispatch_task {
    my($self, $server, $queue, $data, $uniq, $backlog_entry) = @_;
    my($task, $job_handle);
    $task = Gearman::Task->new($queue, \$data, {
        uniq        => $uniq,
        retry_count => $backlog_entry ? undef : $max_retries,
        on_fail     => sub {
            my($err) = @_;
            $err = "unknown error" unless $err;
            $metrics_counter{'total_errors'}++;
            $failed_clients{$server} = $err;
            if($backlog_entry) {
                # already failed previously, just put it back in the backlog
                _debug(sprintf("retrying job %s for %s/%s still fails", $uniq, $server, $queue));
                {
                    lock %backlog;
                    if(!defined $backlog{$server}) {
                        $backlog{$server} = &share([]);
                    }
                    unshift(@{$backlog{$server}}, $backlog_entry);
                }
            } else {
                _error(sprintf("[%s] forwarding to %s failed: %s", $uniq, $server, $err));
                {
                    lock(%backlog);
                    if(!defined $backlog{$server}) {
                        $backlog{$server} = &share([]);
                    }
                    push @{$backlog{$server}}, shared_clone({
                        time   => time(),
                        server => $server,
                        queue  => $queue,
                        data   => $data,
                        uniq   => $uniq,
                    });
                    _error(sprintf("backlog contains %d jobs for %d servers", _count_sub_elements(\%backlog), scalar keys %backlog));
                }
            }
        },
        on_retry    => sub {
            my($attempt) = @_;
            _debug(sprintf("[%s] forwarding to server %s failed, retying: attempt %d/%d", $uniq, $server, $attempt, $max_retries));
        },
        on_complete => sub {
            delete $failed_clients{$server};
        },
    });
    my $client  = $self->_get_client($server);
    my $taskset = $client->new_task_set;
    $taskset->add_task($task);
    $job_handle = $client->dispatch_background($task);
    if($job_handle) {
        _debug(sprintf("[%s] background job dispatched to %s", $uniq, $server));
        delete $failed_clients{$server};
    } else {
        _debug(sprintf("[%s] background job dispatching failed for %s", $uniq, $server));
    }
    return($job_handle);
}

#################################################
sub _worker_work {
    my($self, $worker) = @_;

    my $start = time();
    my $keep_running = 1;
    local $SIG{'HUP'}  = sub {
        _debug(sprintf("worker thread exits by signal %s", "HUP"));
        $worker->reset_abilities() if $worker;
        $keep_running = 0;
    };

    _enable_tcp_keepalive($worker);

    $worker->work(
        on_start => sub {
            my($jobhandle) = @_;
            _debug(sprintf("[%s] job starting", $jobhandle));
        },
        on_complete => sub {
            my($jobhandle, $result) = @_;
            _debug(sprintf("[%s] job completed: %s", $jobhandle, $result));
        },
        on_fail => sub {
            my($jobhandle, $err) = @_;
            $err = "unknown worker error" unless $err;
            next if $err =~ m/\Qgot work_complete for unknown handle:\E/mx; # not a problem
            _error(sprintf("[%s] job failed: %s", $jobhandle, $err));
        },
        stop_if => sub {
            my($is_idle, $last_job_time) = @_;
            _debug(sprintf("stop_if: is_idle=%d - last_job_time=%s keep_running=%s", $is_idle, $last_job_time ? $last_job_time : "never", $keep_running));
            return 1 if ! $keep_running;
            if((!$last_job_time && $start < time() - 60) || ($last_job_time && $last_job_time < time() - 60)) {
                _debug(sprintf("refreshing worker after 1min idle"));
                return 1;
            }
            return;
        },
    );
    return($keep_running);
}

#################################################
sub _backlog_worker {
    my($self) = @_;
    _debug("backlog worker thread started");

    # clean backlog from none-existing client servers
    my $existing_clients = {};
    for my $s (sort keys %{$self->{'queues'}}) {
        for my $q (sort values %{$self->{'queues'}->{$s}}) {
            my $server = $q->{'remoteHost'};
            next unless $server;
            $existing_clients->{$server} = 1;
        }
    }
    {
        lock(%backlog);
        for my $s (sort keys %backlog) {
            delete $backlog{$s} unless $existing_clients->{$s};
        }
    }

    my $keep_running = 1;
    local $SIG{'HUP'}  = sub {
        _debug(sprintf("backlog worker thread exits by signal %s", "HUP"));
        $keep_running = 0;
    };

    while($keep_running) {
        my($count, $server) = (0, []);
        {
            lock %backlog;
            $count  = scalar keys %backlog;
            $server = [sort keys %backlog];
        }
        if($count == 0) {
            sleep 1;
            next;
        }

        # retry failed jobs
        for my $s (@{$server}) {
            while(1) {
                my $job;
                {
                    lock %backlog;
                    last unless $backlog{$s};
                    $job = shift @{$backlog{$s}};
                    if(!$job) {
                        delete $backlog{$s};
                    }
                }
                last unless $job;
                if($job->{'time'} < time() - $backlog_timeout) {
                    _debug(sprintf("discarding job %s for %s/%s, backlog timeout reached, trying since: %s", $job->{'uniq'}, $job->{'server'}, $job->{'queue'}, scalar localtime $job->{'time'}));
                    next;
                }
                _debug(sprintf("retrying job %s for %s/%s", $job->{'uniq'}, $job->{'server'}, $job->{'queue'}));
                if($self->_dispatch_task($job->{'server'}, $job->{'queue'}, $job->{'data'}, $job->{'uniq'}, $job)) {
                    _debug(sprintf("retrying job %s for %s/%s finally worked", $job->{'uniq'}, $job->{'server'}, $job->{'queue'}));
                } else {
                    # still failed, it does not make sense to try more from this server
                    last;
                }
            }
        }
        sleep(15);
    }
    return(threads->exit());
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
    our $queues      = {};
    our $logfile     = "";
    our $debug       = 0;
    our $statusqueue = "";

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

    $self->{'logfile'}     = $self->{'args'}->{'logFile'} // $logfile // 'stdout';
    $self->{'debug'}       = $self->{'args'}->{'debug'} || $debug // 0;
    $self->{'queues'}      = $self->_parse_queues($queues);
    $self->{'statusqueue'} = $statusqueue;

    $debug_log_enabled = $self->{'debug'};
    $logFile           = $self->{'logfile'};
    return;
}

#################################################
sub _parse_queues {
    my($self, $raw) = @_;
    my $queues = {};
    for my $key (sort keys %{$raw}) {
        my($fromserver,$fromqueue) = split(/\//mx, $key, 2);
        my $to = $raw->{$key};
        # simple string declaration
        if(ref $to eq '') {
            $to = {
                "remoteQueue" => "$to",
            };
        }
        if(!$to->{'remoteQueue'}) {
            _error("missing remoteQueue definition in queue configuration");
            _error($to);
            next;
        }
        # expand remote host
        my($remoteHost, $remoteQueue) = split(/\//mx, $to->{'remoteQueue'}, 2);
        $to->{'remoteHost'}  = $remoteHost;
        $to->{'remoteQueue'} = $remoteQueue;
        $to->{'localHost'}   = $fromserver;
        $to->{'localQueue'}  = $fromqueue;

        # check crypto modules
        if($to->{'encrypt'} || $to->{'decrypt'}) {
            eval {
                require Crypt::Rijndael;
                require MIME::Base64;
            };
            my $err = $@;
            if($err) {
                _fatal(sprintf("encrypt/decrypt requires additional modules (Crypt::Rijndael and MIME::Base64) which failed to load: %s", $err));
            }
        }

        $queues->{$fromserver}->{$fromqueue} = $to;
    }
    return($queues);
}

#################################################
sub _encrypt {
    my($self, $txt, $pass) = @_;
    my $cipher = $self->_cipher($pass);
    $txt = _null_pad($txt);
    return(MIME::Base64::encode_base64($cipher->encrypt($txt)));
}

#################################################
sub _decrypt {
    my($self, $txt, $pass) = @_;
    my $cipher = $self->_cipher($pass);
    my $dec = $cipher->decrypt(MIME::Base64::decode_base64($txt));
    # strip null bytes
    $dec =~ s/\x00*$//mx;
    return($dec);
}

#################################################
sub _cipher {
    my($self, $pass) = @_;
    return($self->{'cipher_cache'}->{$pass} ||= do {
        if($pass =~ m/^file:(.*)$/mx) {
            chomp($pass = read_file($1));
        }
        my $key = substr(_null_pad($pass),0,32);
        Crypt::Rijndael->new($key, Crypt::Rijndael::MODE_ECB());
    });
}

#################################################
sub _null_pad {
    my($str) = @_;
    my $pad = (POSIX::ceil(length($str) / 32) * 32) - length($str);
    if(length($str) == 0) { $pad = 32; }
    $str = $str . chr(0) x $pad;
    return($str);
}

#################################################
sub _get_client {
    my($self, $server) = @_;
    return($self->{'clients_cache'}->{$server} ||= do {
        my $client = Gearman::Client->new(job_servers => [$server]);
        _enable_tcp_keepalive($client);
        $client;
    });
}

#################################################
# clear client connection cache and ciphers
sub _reset_counter_and_caches {
    my($self) = @_;
    $self->{'clients_cache'} = {};
    $self->{'cipher_cache'}  = {};
    for my $key (sort keys %metrics_counter) {
        delete $metrics_counter{$key};
    }
    for my $key (sort keys %metrics_bytes) {
        delete $metrics_bytes{$key};
    }
    return;
}

#################################################
# count all elements in hash of hashes
sub _count_sub_elements {
    my($el) = @_;
    my $count = 0;
    for my $s (keys %{$el}) {
        if(ref $el->{$s} eq 'HASH') {
            $count += scalar keys %{$el->{$s}};
        }
        elsif(ref $el->{$s} eq 'ARRAY') {
            $count += scalar @{$el->{$s}};
        }
    }
    return($count);
}

#################################################
sub _status_name {
    my($status) = @_;
    if($status == 0) { return("OK"); }
    if($status == 1) { return("WARNING"); }
    if($status == 2) { return("CRITICAL"); }
    return("UNKNOWN");
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
    my @txt = split(/\n/mx, $txt);
    my($seconds, $microseconds) = gettimeofday;
    for my $t (@txt)  {
        my $pad = ' ';
        if($t =~ m/^\[/mx) { $pad = ''; }
        printf($fh "[%s.%s][%s][thread-%s]%s%s\n",
                    POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime($seconds)),
                    substr(sprintf("%06s", $microseconds), 0, 3), # zero pad microseconds to 6 digits and take the first 3 digits for milliseconds
                    $lvl,
                    threads->tid(),
                    $pad,
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
sub _error {
    my($txt) = @_;
    _out($txt, "ERROR");
    return;
}

#################################################
sub _warn {
    my($txt) = @_;
    _out($txt, "WARNING");
    return;
}

#################################################
sub _info {
    my($txt) = @_;
    _out($txt, "INFO");
    return;
}

#################################################
sub _debug {
    my($txt) = @_;
    return unless $debug_log_enabled;
    _out($txt, "DEBUG");
    return;
}

#################################################

=head1 AUTHOR

Sven Nierlein, 2009-present, <sven@nierlein.org>

=head1 LICENSE

GearmanProxy is Copyright (c) 2009-2020 by Sven Nierlein.
This is free software; you can redistribute it and/or modify it under the
same terms as the Perl5 programming language system itself.

=cut

1;
