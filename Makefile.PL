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

requires 'Gearman::Worker'       => 0;
requires 'Gearman::Client'       => 0;
requires 'Socket'                => 0;
requires 'Crypt::Rijndael'       => 0;
requires 'MIME::Base64'          => 0;
requires 'File::Slurp'           => 0;

# touch the Makefile, so Extutils skips its broken 'check_manifest()'
`touch Makefile`;

install_script glob('script/*.pl');
eval {
    require CPAN;
    installdeps_target();
};
WriteAll;

open(my $fh, '>>', 'Makefile') or die('cannot write to Makefile');
print $fh <<EOT;
gearman_proxy.pl ::
	echo '#!/usr/bin/perl'      > ./gearman_proxy.pl
	echo ''                    >> ./gearman_proxy.pl
	cat ./lib/GearmanProxy.pm lib/GearmanProxy/Log.pm ./script/gearman_proxy.pl | grep -v '^use GearmanProxy' | grep -v '__END__' >> ./gearman_proxy.pl
	chmod 755 ./gearman_proxy.pl
EOT
close($fh);
