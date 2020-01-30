use strict;
use warnings;
use Test::More;

my $filter = $ARGV[0];
my $cmds = [
  "grep -nr 'TODO' lib/. *.pl t/",
];

# find all TODOs
for my $cmd (@{$cmds}) {
  open(my $ph, '-|', $cmd.' 2>&1') or die('cmd '.$cmd.' failed: '.$!);
  ok($ph, 'cmd started');
  while(<$ph>) {
    my $line = $_;
    chomp($line);
    next if($filter && $line !~ m%$filter%mx);

    # skip those
    if($line =~ m|/092\-todo\.t|mx) {
      next;
    }

    # let them really fail
    fail($line);
  }
  close($ph);
}


done_testing();
