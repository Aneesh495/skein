use strict;
use warnings;
use Test::More;
use Skein::Model;
use Skein::Compiler;
use Skein::BDD::Count qw(weighted_count);
use Skein::Rat qw(text);

my $model = Skein::Model->from_text(<<'MODEL');
noise u ~ 1/2;
noise v ~ 1/3;
node a = u;
node b = a ^ v;
query q = P(b) factual(b) do(a=0);
MODEL
my $compiler = Skein::Compiler->new($model);
my $world = $compiler->world;
for my $mask (0 .. 3) {
    my %noise = (u => $mask & 1, v => ($mask >> 1) & 1);
    my $reference = $model->world(\%noise);
    for my $node (qw(a b)) {
        is($compiler->bdd->evaluate($world->{$node}, \%noise), $reference->{$node}, 'compiled factual equation');
    }
    my $changed = $compiler->world({a => 0});
    my $reference_changed = $model->world(\%noise, {a => 0});
    is($compiler->bdd->evaluate($changed->{b}, \%noise), $reference_changed->{b}, 'compiled intervention');
}
my $roots = $compiler->query($model->query('q'));
is(text(weighted_count($compiler->bdd, $roots->{denominator}, $model->priors)), '1/2', 'factual evidence shared noise');
is(text(weighted_count($compiler->bdd, $roots->{numerator}, $model->priors)), '1/6', 'joint counterfactual mass');
ok($compiler->bdd->assert_invariants, 'compiled invariants');
my $reversed = Skein::Compiler->new($model, order => [qw(v u)]);
my $other = $reversed->query($model->query('q'));
is(text(weighted_count($reversed->bdd, $other->{numerator}, $model->priors)), '1/6', 'alternate order retains mass');
ok(!eval { Skein::Compiler->new($model, order => ['u']); 1 }, 'incomplete order rejected');
done_testing;
