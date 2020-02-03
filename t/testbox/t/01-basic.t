#!/usr/bin/perl

use warnings;
use strict;
use Test::More tests => 2;

# force check of worker ping


my $res = `/omd/sites/demo/lib/monitoring-plugins/check_gearman -H 127.0.0.1:4730 -q proxy_status -s check`;
is($?, 0, "check_gearman worked");
like($res, "/check_gearman OK/", "result contains OM");