use strict;
use warnings;
use Test::More;
use Skein::BDD;
use Skein::BDD::Transform qw(restrict quantify compose transfer support sat_count cubes export_diagram import_diagram);

my $bdd = Skein::BDD->new([qw(a b c unused)]);
my ($a, $b, $c) = map { $bdd->variable($_) } qw(a b c);
my $root = $bdd->apply('or', $bdd->apply('and', $a, $b), $c);
is(restrict($bdd, $root, {c => 0}), $bdd->apply('and', $a, $b), 'cofactor');
is(quantify($bdd, $root, ['a'], 'exists'), $bdd->apply('or', $b, $c), 'existential projection');
is(quantify($bdd, $root, ['a'], 'forall'), $c, 'universal projection');
is(compose($bdd, $root, {a => $bdd->negate($b)}), $c, 'substitution can introduce earlier variables');
is_deeply(support($bdd, $root), [qw(a b c)], 'diagram support');
is(sat_count($bdd, $root)->bstr, '10', 'model count accounts for skipped variables');
is(sat_count($bdd, 1)->bstr, '16', 'true terminal count');
is(sat_count($bdd, 0)->bstr, '0', 'false terminal count');
my $other = Skein::BDD->new([qw(unused c b a)]);
my $converted = transfer($bdd, $other, $root);
for my $mask (0 .. 15) {
    my %assignment = (a => $mask & 1, b => ($mask >> 1) & 1, c => ($mask >> 2) & 1, unused => ($mask >> 3) & 1);
    is($other->evaluate($converted, \%assignment), $bdd->evaluate($root, \%assignment), 'reordered semantics');
}
my $data = export_diagram($bdd, [$root, $bdd->negate($root)]);
my ($loaded, $roots) = import_diagram($data);
is(sat_count($loaded, $roots->[0])->bstr, '10', 'diagram round trip');
ok($loaded->assert_invariants, 'loaded invariants');
my $paths = cubes($bdd, $root);
is(scalar @$paths, 3, 'disjoint satisfying cubes');
ok(!eval { cubes($bdd, $root, limit => 1); 1 }, 'cube limit is explicit');
$data->{nodes}[0]{high} = 9999;
ok(!eval { import_diagram($data); 1 }, 'corrupt edge rejected');
done_testing;
