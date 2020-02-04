use strict;
use warnings;
use Test::More;

my $cmds = {
  "grep -nr 'print STDERR Dumper' ./lib/ ./t/ ./script/*.pl" => {},
};

# find all missed debug outputs
for my $cmd (keys %{$cmds}) {
  my $opt = $cmds->{$cmd};
  open(my $ph, '-|', $cmd.' 2>&1') or die('cmd '.$cmd.' failed: '.$!);
  ok($ph, 'cmd started');
  while(<$ph>) {
    my $line = $_;
    chomp($line);
    $line =~ s|//|/|gmx;

    next if $line =~ m|092\-clean_debug\.t|mx;

    if($opt->{'skip_comments'}) {
        if($line =~ m|^[a-zA-Z\./\-]+:\d+:\s*\#|mx) { next; }
    }
    if($opt->{'exclude'}) {
        my $matched = 0;
        for my $r (@{$opt->{'exclude'}}) {
            if($line =~ /$r/mx) { $matched = 1; last; }
        }
        next if $matched;
    }

    fail($line);
  }
  close($ph);
}


done_testing();
