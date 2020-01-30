use strict;
use warnings;
use Test::More;

use_ok("ExtUtils::Manifest");

# first do a make distcheck
SKIP: {
    # https://github.com/Perl-Toolchain-Gang/ExtUtils-Manifest/issues/5
    skip "distcheck is broken with ExtUtils::Manifest >= 1.66", 1 if $ExtUtils::Manifest::VERSION >= 1.66;
    open(my $ph, '-|', 'make distcheck 2>&1') or die('make failed: '.$!);
    while(<$ph>) {
        my $line = $_;
        chomp($line);

        if(   $line =~ m/\/bin\/perl/
           or $line =~ m/: Entering directory/
           or $line =~ m/: Leaving directory/
        ) {
          pass($line);
          next;
        }

        if($line =~ m/No such file: (.*)$/) {
            if( -l $1) {
              pass("$1 is a symlink");
            } else {
              fail("$1 does not exist!");
            }
            next;
        }

        fail($line);
    }
    close($ph);
    ok($? == 0, 'make exited with: '.$?);
};

# read our manifest file
my $manifest = {};
open(my $fh, '<', 'MANIFEST') or die('open MANIFEST failed: '.$!);
while(<$fh>) {
    my $line = $_;
    chomp($line);
    next if $line =~ m/^#/;
    $manifest->{$line} = 1;
}
close($fh);
ok(scalar keys %{$manifest} >  0, 'read entrys from MANIFEST: '.(scalar keys %{$manifest}));

# read our manifest.skip file
my $manifest_skip = {};
open($fh, '<', 'MANIFEST.SKIP') or die('open MANIFEST.SKIP failed: '.$!);
while(<$fh>) {
    my $line = $_;
    chomp($line);
    next if $line =~ m/^#/;
    $manifest_skip->{$line} = 1;
}
close($fh);
ok(scalar keys %{$manifest_skip} >  0, 'read entrys from MANIFEST.SKIP: '.(scalar keys %{$manifest_skip}));


done_testing();
