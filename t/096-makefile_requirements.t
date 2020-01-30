use strict;
use warnings;
use Test::More;
use File::Slurp qw/read_file/;

my $replace = {
};

# first get all we have already
my $reqs = _get_reqs();

# then get all requirements
my $all_used = {};
my $files    = _get_files('lib', '*.pl');
my $packages = _get_packages($files);
for my $file (@{$files}) {
  my $subs    = _get_modules_from_subs($file);
  my $modules = _get_imported_modules($file);
  for my $mod (@{$modules}) {
    delete $subs->{$mod};
    next if _is_core_module($mod);
    $all_used->{$mod} = 1;
    $mod = $replace->{$mod} if defined $replace->{$mod};
    if(defined $reqs->{$mod}) {
      pass("$mod required by $file exists in Makefile.PL");
    }
    elsif(defined $packages->{$mod}) {
      pass("$mod required by $file is shipped");
    }
    elsif($file =~ m|^t/|) {
      if(defined $reqs->{'author_test'}->{$mod}) {
        pass("$mod required by $file is in authors section");
      }
    }
    else {
      next if $mod =~ m/^Devel/mx;
      fail("$mod required by $file missing");
    }
  }

  # too many false positives otherwise...
  if($file =~ m/script/mx && $file !~ m/^t\//mx && $file !~ m/\/lib\//mx) {
    for my $mod (sort keys %{$subs}) {
      fail("missing use/require for $mod in $file");
    }
  }

  # try to remove some commonly unused modules
  my $content = read_file($file);
  if(grep/^\QCarp\E$/mx, @{$modules}) {
    if($content !~ /confess|croak|cluck|longmess/mxi) {
      fail("using Carp could be removed from $file");
    }
  }
  if(grep/^\Qutf8\E$/mx, @{$modules}) {
    if($content !~ /utf8::/mxi) {
      fail("using utf8 could be removed from $file");
    }
  }
  if(grep/^\QData::Dumper\E$/mx, @{$modules}) {
    if($content !~ /Dumper\(/mxi) {
      fail("using Data::Dumper could be removed from $file");
    }
  }
  if(grep/^\QPOSIX\E$/mx, @{$modules}) {
    if($content !~ /POSIX::/mxi) {
      fail("using POSIX could be removed from $file");
    }
  }
}

# check if some modules can be removed from the Makefile.PL
for my $mod (sort keys %{$reqs}) {
  if(ref $reqs->{$mod} eq 'HASH') {
    for my $pmod (sort keys %{$reqs->{$mod}}) {
      if(!defined $all_used->{$pmod} && (!defined $replace->{$pmod} || !defined $all_used->{$replace->{$pmod}})) {
        next if $pmod =~ m/^Perl::Critic/mx;
        next if $pmod eq 'Test::Simple';
        fail("$pmod not used at all");
      }
    }
  } else {
    if(!defined $all_used->{$mod} && (!defined $replace->{$mod} || !defined $all_used->{$replace->{$mod}})) {
      fail("$mod not used at all");
    }
  }
}

done_testing();

#################################################
sub _get_files {
  my $files = [];
  for my $f (@_) {
    my @entries = glob($f);
    for my $entry (@entries) {
      if(-d $entry) {
        push @{$files}, @{_get_files(glob($entry.'/*'))};
      } else {
        push @{$files}, $entry if $entry =~ m/\.(pl|pm|t)$/;
      }
    }
  }
  return $files;
}

#################################################
sub _get_packages {
  my $files = shift;
  for my $file (@{$files}) {
    open(my $fh, '<', $file) or die("cannot open $file: $!");
    while(my $line = <$fh>) {
      if($line =~ m/^\s*package\s+([^\s]+)/) {
        $packages->{$1} = 1;
        last;
      }
    }
    close($fh);
  }
  my $new_pack = {};
  for my $key (sort keys %{$packages}) {
    $key = _clean($key);
    $new_pack->{$key} = 1;
  }
  return $new_pack;
}

#################################################
sub _get_imported_modules {
  my($file)    = @_;
  my $modules  = {};
  my $content  = read_file($file);
  # remove pod
  $content =~ s|^=.*?^=cut||sgmx;
  for my $line (split/\n+/mx, $content) {
    next if $line =~ m|^\s*\#|mx;
    if($line =~ m/(^|eval.*)\s*(use|require)\s+(\S+)/) {
      $modules->{$3} = 1;
    }
    if($line =~ m/^\s*use\s+base\s+([^\s]+)/) {
      $modules->{$1} = 1;
    }
    if($line =~ m/^\s*load\s+([^\s]+)(,|;)/) {
      $modules->{$1} = 1;
    }
    if($line =~ m/^\s*use\s+parent\s+([^\s]+)/) {
      $modules->{$1} = 1;
    }
    if($line =~ m/(^|\s+)require\s+([^\s]+)/) {
      my $mod = $2;
      $mod =~ s|['"]*||gmx;
      next if $mod =~ /^\$/mx;
      $modules->{$mod} = 1;
    }
  }
  my @mods;
  for my $key (sort keys %{$modules}) {
    $key = _clean($key);
    $key =~ s/^qw\((.*?)\)/$1/gmx;
    next if $key =~ m/^\d+\.\d+$/;
    next if $key =~ m/^\s*$/;
    next if $key =~ m/^\s*\$/;
    $all_used->{$key} = 1;
    next if $key =~ m/^lib\(/;
    next if $key eq 'base';
    next if $key eq 'strict';
    next if $key eq 'warnings';
    next if $key eq 'utf8';
    next if $key eq 'UNIVERSAL';
    push @mods, $key;
  }
  return \@mods;
}

#################################################
sub _get_modules_from_subs {
  my($file)    = @_;
  my $modules  = {};
  my $content  = read_file($file);
  # remove pod
  $content =~ s|^=.*?^=cut||sgmx;
  my $package;
  for my $line (split/\n+/mx, $content) {
    next if $line =~ m|^\s*\#|mx;
    if($line =~ m/^\s*package\s*([\w:]+)(;|\s|$)/mx) {
      $package = $1;
    }
    if($line =~ m/(^|\s|\()(\w+::[\w:]+)\(/mx) {
      my $mod = $2;
      $mod =~ s/::[^:]+$//gmx;
      next if $package && $package eq $mod;
      next if $mod eq 'CORE';
      $modules->{$mod} = 1;
    }
  }
  return($modules)
}

#################################################
my %_stdmod;
sub _is_core_module {
  my($module) = @_;

  unless (keys %_stdmod) {
    chomp(my $perlmodlib = `perldoc -l perlmodlib`);
    die "cannot locate perlmodlib\n" unless $perlmodlib;

    open my $fh, "<", $perlmodlib
      or die "$0: open $perlmodlib: $!\n";

    while (<$fh>) {
      next unless /^=head\d\s+Pragmatic\s+Modules/ ..
                  /^=head\d\s+CPAN/;

      if (/^=item\s+(\w+(::\w+)*)/) {
        ++$_stdmod{ lc $1 };
      }
    }
  }

  exists $_stdmod{ lc $module } ? $module : ();
}

#################################################
sub _get_reqs {
  my $reqs = {};
  my $file = "Makefile.PL";
  my $in_feature;
  open(my $fh, '<', $file) or die("cannot open $file: $!");
  while(my $line = <$fh>) {
    if($line =~ m/^\s*requires\s([^\s]+)\s/) {
      my $key = _clean($1);
      $reqs->{$key} = 0;
    }
    if(defined $in_feature && $line =~ m/^\s*'(.*?)'/) {
      $reqs->{$in_feature}->{_clean($1)} = 1;
    }
    if(defined $in_feature && $line =~ m/^\s\);/) {
      undef $in_feature;
    }
    if($line =~ m/^\s*feature\s*\('(.*?)',/) {
      $in_feature = _clean($1);;
      $reqs->{$in_feature} = {};
    }
  }
  close($fh);
  return $reqs;
}

#################################################
sub _clean {
  my $key = shift;
  $key =~ s/;$//;
  $key =~ s/^'//;
  $key =~ s/'$//;
  $key =~ s/^"//;
  $key =~ s/"$//;
  $key =~ s/^qw\///;
  $key =~ s/\/$//;
  $key =~ s/;$//;
  return $key;
}
