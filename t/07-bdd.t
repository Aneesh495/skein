use strict;
use warnings;
use Test::More;
use Skein::BDD;

my $bdd = Skein::BDD->new([qw(a b c)]);
my @vars = map { $bdd->variable($_) } qw(a b c);
is($bdd->variable('a'), $vars[0], 'unique variable node');
for my $table (0 .. 15) {
    my $root = $bdd->apply($table, $vars[0], $vars[1]);
    for my $mask (0 .. 7) {
        my %assignment = (a => ($mask >> 2) & 1, b => ($mask >> 1) & 1, c => $mask & 1);
        my $index = ($assignment{a} << 1) | $assignment{b};
        is($bdd->evaluate($root, \%assignment), ($table >> $index) & 1, "table $table assignment $mask");
    }
}
my $and = $bdd->apply('and', $vars[0], $vars[1]);
is($bdd->apply('and', $vars[1], $vars[0]), $and, 'commutative canonical root');
is($bdd->negate($bdd->negate($and)), $and, 'double negation canonical');
is($bdd->apply('or', $and, $bdd->negate($and)), 1, 'excluded middle');
for my $k (0 .. 3) {
    for my $exact (0, 1) {
        my $root = $bdd->threshold(\@vars, $k, $exact);
        for my $mask (0 .. 7) {
            my %assignment = (a => ($mask >> 2) & 1, b => ($mask >> 1) & 1, c => $mask & 1);
            my $count = $assignment{a} + $assignment{b} + $assignment{c};
            is($bdd->evaluate($root, \%assignment), $exact ? ($count == $k ? 1 : 0) : ($count >= $k ? 1 : 0),
                "threshold k=$k exact=$exact mask=$mask");
        }
    }
}
my $duplicate = $bdd->threshold([$vars[0], $vars[0]], 1, 1);
is($duplicate, 0, 'correlated duplicate threshold arguments');
ok($bdd->assert_invariants, 'diagram invariants');
ok(!eval { $bdd->mk(1, $vars[0], 1); 1 }, 'order violation rejected');
ok(!eval { $bdd->apply('and', 999, 0); 1 }, 'invalid node rejected');
my $tiny = Skein::BDD->new([qw(a b)], max_nodes => 3);
$tiny->variable('a');
ok(!eval { $tiny->variable('b'); 1 }, 'node bound explicit');
done_testing;
