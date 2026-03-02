use strict;
use warnings;
use Test::More;
use Skein::Campaign;

my $a = Skein::Campaign->new(seed => 'unit-campaign')->run(cases => 7,functions => 256,families => 256);
ok($a->{passed},'differential campaign passes');
is($a->{queries},35,'all query kinds executed');
ok($a->{assertions} > 30_000,'complete small-function invariants executed');
is($a->{functions},256,'every three-variable Boolean function checked');
my $b = Skein::Campaign->new(seed => 'unit-campaign')->run(cases => 7,functions => 0,families => 0);
is_deeply($a->{records},$b->{records},'causal cases reproduce independent of later campaign phases');
my $c = Skein::Campaign->new(seed => 'unit-campaign')->run(cases => 7,functions => 0,families => 0);
is($b->{receipt},$c->{receipt},'identical campaigns have identical result receipts');
done_testing;
