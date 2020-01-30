use strict;
use warnings;
use inc::Module::Install;

name 'GearmanProxy';
all_from 'lib/GearmanProxy.pm';

license 'perl';
resources(
    'homepage',   => 'https://github.com/sni/gearman-proxy',
    'bugtracker'  => 'https://github.com/sni/gearman-proxy/issues',
    'repository', => 'https://github.com/sni/gearman-proxy',
    'license'     => 'http://dev.perl.org/licenses/',
);

requires 'Pod::Usage'            => 0;
requires 'Getopt::Long'          => 0;
requires 'Gearman::Worker'       => 0;
requires 'Gearman::Client'       => 0;
requires 'threads'               => 0;
requires 'Data::Dumper'          => 0;
requires 'Socket'                => 0;
requires 'POSIX'                 => 0;
requires 'Time::HiRes'           => 0;
requires 'sigtrap'               => 0;


# touch the Makefile, so Extutils skips its broken 'check_manifest()'
`touch Makefile`;

install_script glob('script/*.pl');
eval {
    require CPAN;
    installdeps_target();
};
WriteAll;