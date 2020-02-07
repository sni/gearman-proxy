#!/usr/bin/perl

use warnings;
use strict;
use Test::More tests => 9;

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
    like($res, "/check_gearman OK/", "result contains OM");
    like($res, "/queues=2/", "result contains queues");
    like($res, "/server=2/", "result contains server");
    like($res, "/'hostgroup_worker1::jobs'=\\dc/", "result contains hostgroup_worker1::jobs");
};
