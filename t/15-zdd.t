use strict;
use warnings;
use Test::More;
use Skein::ZDD;

sub normalized {
    my ($sets) = @_;
    return [sort map { join ',', sort @$_ } @$sets];
}

my $zdd = Skein::ZDD->new([qw(a b c)]);
my $left = $zdd->from_sets([[], ['a'], [qw(a b)], [qw(b c)]]);
my $right = $zdd->from_sets([['b'], [qw(a b)]]);
is($zdd->count($left)->bstr, '4', 'family cardinality');
is_deeply(normalized($zdd->sets($zdd->intersection($left, $right))), ['a,b'], 'intersection');
is_deeply(normalized($zdd->sets($zdd->difference($left, $right))), ['', 'a', 'b,c'], 'difference');
is_deeply(normalized($zdd->sets($zdd->minimal($left))), [''], 'empty set subsumes all');
my $family = $zdd->from_sets([['a'], [qw(a b)], [qw(b c)]]);
is_deeply(normalized($zdd->sets($zdd->minimal($family))), ['a', 'b,c'], 'antichain minimization');
my $product = $zdd->product($zdd->from_sets([['a'], ['b']]), $zdd->from_sets([['b'], ['c']]));
is_deeply(normalized($zdd->sets($product)), ['a,b', 'a,c', 'b', 'b,c'], 'set union product');
is_deeply(normalized($zdd->sets($zdd->exclude_supersets($product, $zdd->singleton(['b'])))), ['a,c'], 'subset exclusion');
is($zdd->mk(0, 1, 0), 1, 'zero suppression');
ok($zdd->assert_invariants, 'ZDD invariants');
ok(!eval { $zdd->sets($left, limit => 2); 1 }, 'enumeration bound');
ok(!eval { $zdd->singleton(['absent']); 1 }, 'unknown set element');
done_testing;
