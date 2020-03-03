use strict;
use warnings;
use Test::More;
use File::Slurp qw/read_file/;

plan( skip_all => 'broken on travis, it just hangs') if $ENV{TRAVIS_BRANCH};
plan( tests => 15);

use_ok("GearmanProxy");
use_ok("Gearman::Worker");
use_ok("MIME::Base64");
use_ok("Crypt::Rijndael");

################################################################################
# start test gearmand on testport in background
my $testport = "50001";
my $gearmand_pid;
my $gearmand_pidfile = "test_gearman.pid";
my $gearmand_logfile = "test_gearman.log";
{
    my $cmdline  = "gearmand -d -P $gearmand_pidfile -p $testport -l $gearmand_logfile 2>&1 &";
    ok(1, $cmdline);
    system($cmdline);
    # wait till its started
    for my $x (0..10) {
        if(-e $gearmand_pidfile) {
            chomp($gearmand_pid = read_file($gearmand_pidfile));
            ok(1, "gearmand started after $x seconds with pid: $gearmand_pid");
            last;
        }
        sleep(1);
    }
    if(!$gearmand_pid) {
        BAIL_OUT("gearmand failed to start");
    }
};

################################################################################
# start test proxy
my $proxy_pid;
my $proxy_pidfile  = "proxy.pid";
my $proxy_logfile  = "proxy.log";
{
    my $cmdline  = "./script/gearman_proxy.pl --pid=$proxy_pidfile --log=$proxy_logfile --config=t/gearman_proxy.cfg 2>&1 &";
    ok(1, $cmdline);
    system($cmdline);
    # wait till its started
    for my $x (0..10) {
        if(-e $proxy_pidfile) {
            chomp($proxy_pid = read_file($proxy_pidfile));
            ok(1, "proxy started after $x seconds with pid: $proxy_pid");
            last;
        }
        sleep(1);
    }
    if(!$proxy_pid) {
        BAIL_OUT("proxy failed to start");
    }
};

################################################################################
# do some tests
my $testserver = "127.0.0.1:".$testport;
my $proxy      = GearmanProxy->new({});
my $client     = $proxy->_get_client($testserver);

# plain text forward
{
    my $testdata   = read_file("t/testdata.plain");
    my $job        = $client->dispatch_background("in1", $testdata, { uniq => "test1" });
    isnt(undef, $job, "submitted test job to queue in1");

    # fetch result from out1 queue
    my $testresult = _fetch_result($testserver, "out1");
    is($testdata, $testresult, "simple forward data");
    my $data = MIME::Base64::decode_base64($testdata);
    like($data, '/result_queue=check_results/', "test data contains result_queue");
};

################################################################################
# encrypted text forward
{
    my $testdata   = read_file("t/testdata.crypt");
    my $job        = $client->dispatch_background("in2", $testdata, { uniq => "test2" });
    isnt(undef, $job, "submitted test job to queue in2");

    # fetch result from out1 queue
    my $testresult = _fetch_result($testserver, "out2");
    my $data       = $proxy->_decrypt($testresult, "secret");
    like($data, '/result_queue=results_test/', "test data contains result_queue");
};

################################################################################
# status information
{
    my $testdata   = "status";
    my $result_ref = $client->do_task("proxy_status", "status");
    like($$result_ref, '/running/', "got status answer");
    like($$result_ref, '/in1/', "status answer contains counter");
};

################################################################################
# kill gearmand and proxy
_cleanup();
exit(0);

sub _cleanup {
    kill('TERM', $gearmand_pid) if $gearmand_pid;
    kill('TERM', $proxy_pid) if $proxy_pid;
    unlink($gearmand_pidfile);
    unlink($gearmand_logfile);
    unlink($proxy_pidfile);
    unlink($proxy_logfile);
}

################################################################################
END {
    _cleanup();
};

################################################################################
sub _fetch_result {
    my($server, $queue) = @_;
    my $worker = Gearman::Worker->new(job_servers => [ $server ]);
    my $testresult;
    $worker->register_function($queue => sub { $testresult = $_[0]->arg; });
    $worker->work(stop_if => sub { return($testresult ? 1 : 0); });
    return($testresult);
}
