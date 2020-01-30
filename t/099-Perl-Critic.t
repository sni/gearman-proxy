#!/usr/bin/env perl
#
# $Id$
#
use strict;
use warnings;
use Test::More;
use English qw(-no_match_vars);

eval { require Test::Perl::Critic; };

if($EVAL_ERROR) {
   my $msg = 'Test::Perl::Critic required to criticise code';
   plan( skip_all => $msg );
}

my $rcfile = 't/perlcriticrc';
Test::Perl::Critic->import( -profile => $rcfile );

my $dirs = [ 'lib' ];
my @files = Perl::Critic::Utils::all_perl_files(@{$dirs});
plan( tests => scalar @files);
for my $file (sort @files) {
    my $ctx = Digest::MD5->new;
    open(FILE, '<', $file);
    $ctx->addfile(*FILE);
    close(FILE);
    critic_ok($file);
}
