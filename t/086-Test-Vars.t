#!/usr/bin/env perl

use warnings;
use strict;
use Test::More;

eval { require Test::Vars; };

if($@) {
   my $msg = 'Test::Vars required for this test';
   plan( skip_all => $msg );
}

Test::Vars->import();
all_vars_ok(ignore_vars => [qw()]);
