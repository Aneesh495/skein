use strict;
use warnings;
use Test::More;
use Skein::BDD;
use Skein::BDD::Count qw(weighted_count gradient);
use Skein::Polynomial;
use Skein::Rat qw(text);

my $bdd = Skein::BDD->new([qw(a b c)]);
my ($a, $b, $c) = map { $bdd->variable($_) } qw(a b c);
my $root = $bdd->apply('or', $a, $bdd->apply('and', $b, $c));
my $polynomial = Skein::Polynomial->from_bdd($bdd, $root);
is_deeply($polynomial->terms, {'1,0,0' => '1', '0,1,1' => '1', '1,1,1' => '-1'}, 'exact reliability polynomial');
ok($polynomial->multilinear, 'square-free invariant');
for my $priors (
    {a => '1/3', b => '1/5', c => '1/7'}, {a => 0, b => 1, c => 1},
    {a => '1/2', b => '1/2', c => '1/2'},
) {
    is(text($polynomial->evaluate($priors)), text(weighted_count($bdd, $root, $priors)), 'polynomial and diagram mass');
    my $derivatives = gradient($bdd, $root, $priors)->{derivatives};
    for my $name (qw(a b c)) {
        is(text($polynomial->derivative($name)->evaluate($priors)), text($derivatives->{$name}), 'symbolic derivative');
    }
}
is(text($polynomial->specialize({a => 0})->evaluate({b => '1/5', c => '1/7'})), '1/35', 'partial specialization');
my $constant = Skein::Polynomial->constant([], '2/3');
is(text($constant->times($constant)->evaluate({})), '4/9', 'zero-dimensional polynomial product');
ok(!eval { Skein::Polynomial->from_bdd($bdd, $root, max_terms => 1); 1 }, 'symbolic term bound');
done_testing;
