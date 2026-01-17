use strict;
use warnings;
use Test::More;
use Skein::BDD;
use Skein::BDD::Count qw(weighted_count gradient conditional_gradient posterior);
use Skein::Rat qw(text subr);

my $bdd = Skein::BDD->new([qw(a b unused)]);
my ($a, $b) = map { $bdd->variable($_) } qw(a b);
my $root = $bdd->apply('or', $a, $b);
my %priors = (a => '1/3', b => '1/4', unused => '1/7');
is(text(weighted_count($bdd, $root, \%priors)), '1/2', 'overlap counted once');
my $g = gradient($bdd, $root, \%priors);
is(text($g->{derivatives}{a}), '3/4', 'Birnbaum derivative a');
is(text($g->{derivatives}{b}), '2/3', 'Birnbaum derivative b');
is(text($g->{derivatives}{unused}), '0', 'skipped-variable derivative zero');
for my $name (qw(a b unused)) {
    my %low = (%priors, $name => '0');
    my %high = (%priors, $name => '1');
    is(text(subr(weighted_count($bdd, $root, \%high), weighted_count($bdd, $root, \%low))),
        text($g->{derivatives}{$name}), 'exact endpoint derivative');
}
my $joint = $bdd->apply('and', $root, $a);
my $cg = conditional_gradient($bdd, $joint, $root, \%priors);
is(text($cg->{probability}), '2/3', 'conditional mass');
is(text($cg->{derivatives}{a}), '1', 'quotient derivative a');
is(text($cg->{derivatives}{b}), '-8/9', 'quotient derivative b');
my $post = posterior($bdd, $root, \%priors);
is(text($post->{a}), '2/3', 'posterior a');
is(text($post->{b}), '1/2', 'posterior b');
is(text($post->{unused}), '1/7', 'unused noise retains prior');
ok(!eval { posterior($bdd, 0, \%priors); 1 }, 'impossible evidence rejected');
ok(!eval { weighted_count($bdd, $root, {a => '1/2'}); 1 }, 'missing priors rejected');
ok(!eval { weighted_count($bdd, 1, {%priors, bad => '1/2'}); 1 }, 'unknown prior rejected');
done_testing;
