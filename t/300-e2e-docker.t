use strict;
use warnings;
use Test::More;
use Time::HiRes qw/gettimeofday tv_interval/;

# check if docker is available
my $has_docker;
for my $path (split/:/mx, $ENV{'PATH'}) {
    $has_docker = 1 if -x $path.'/docker';
}
plan( skip_all => "docker is required to run this test") unless $has_docker;
plan( skip_all => 'broken on travis, it just hangs') if $ENV{TRAVIS_BRANCH};
plan( tests => 12);

my $verbose = $ENV{'HARNESS_IS_VERBOSE'} ? 1 : undef;

chdir("t/testbox") or BAIL_OUT("chdir failed: $!");
for my $step (qw/clean update prepare wait_start test_verbose clean/) {
    _run($step);
}

sub _run {
    my($step) = @_;

    my $t0 = [gettimeofday];
    ok(1, "running make $step");
    my $out = `make $step 2>&1`;
    my $rc = $?;
    is($rc, 0, sprintf("step %s complete, rc=%d duration=%.1fsec", $step, $rc, tv_interval ($t0)));
    # already printed in verbose mode
    if(!$verbose && $rc != 0) {
        diag("*** make output ***************-");
        diag($out);
        diag("********************************");
    };
    if($step eq "prepare" && $rc != 0) {
        diag(`docker ps`);
        BAIL_OUT("$step failed");
    }
}
