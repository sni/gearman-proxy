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
use GearmanProxy;

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
            'v|version'  => sub { printf("%s - version %s\n", $0, $GearmanProxy::VERSION); exit(3); },
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
