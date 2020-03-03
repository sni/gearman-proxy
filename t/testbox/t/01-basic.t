#!/usr/bin/perl

use warnings;
use strict;
use Test::More tests => 13;

# force check of worker PING
{
    my $res = `thruk r -d "" /services/worker1/PING/cmd/schedule_forced_svc_check 2>&1`;
    is($?, 0, "reschedule worked");
    like($res, "/Command successfully submitted/", "reschedule was successfull");
};

# force check of proxy status
{
    my $res = `thruk r -d "" /services/localhost/gearman%20proxy/cmd/schedule_forced_svc_check 2>&1`;
    is($?, 0, "reschedule worked");
    like($res, "/Command successfully submitted/", "reschedule was successfull");
};

# run check_gearman
{
    my $res = `/omd/sites/demo/lib/monitoring-plugins/check_gearman -H 127.0.0.1:4730 -q proxy_status -s check`;
    is($?, 0, "check_gearman worked");
    like($res, "/OK - proxy version/", "result contains OK");
    like($res, "/queues=3/", "result contains queues");
    like($res, "/server=2/", "result contains server");
    like($res, "/'hostgroup_worker1::jobs'=[0-9]+c/", "result contains hostgroup_worker1::jobs");
};

# run check_gearman on demo worker
{
    my $res = `/omd/sites/demo/lib/monitoring-plugins/check_gearman -H 127.0.0.1:4730 -q worker_demo -s check`;
    is($?, 0, "check_gearman worked");
    like($res, "/check_gearman OK - demo has/", "result contains output");
};

# run check_gearman on worker1 worker
{
    my $res = `/omd/sites/demo/lib/monitoring-plugins/check_gearman -H 127.0.0.1:4730 -q worker_worker1 -s check`;
    is($?, 0, "check_gearman worked");
    like($res, "/check_gearman OK - worker1 has/", "result contains output");
};
