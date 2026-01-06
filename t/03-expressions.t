use strict;
use warnings;
use Test::More;
use Skein::Expr qw(const var op evaluate support simplify render substitute validate);

my $a = var('a');
my $b = var('b');
for my $operator (qw(and or xor implies eq)) {
    my %expected = (
        and => [0, 0, 0, 1], or => [0, 1, 1, 1],
        xor => [0, 1, 1, 0], implies => [1, 1, 0, 1], eq => [1, 0, 0, 1],
    );
    for my $mask (0 .. 3) {
        is(evaluate(op($operator, $a, $b), {a => $mask >> 1, b => $mask & 1}),
            $expected{$operator}[$mask], "$operator truth table $mask");
    }
}
is(evaluate(op('ite', $a, $b, const(1)), {a => 0, b => 0}), 1, 'conditional');
is(evaluate(op('atleast', 2, $a, $b, const(1)), {a => 1, b => 0}), 1, 'threshold');
is(evaluate(op('exactly', 2, $a, $b, const(1)), {a => 1, b => 1}), 0, 'exact cardinality');
is_deeply(support(op('and', $a, op('or', $a, $b))), [qw(a b)], 'unique support');
is(render(simplify(op('and', $a, const(1)))), 'a', 'constant propagation');
is(render(simplify(op('not', op('not', $a)))), 'a', 'double negation');
is(render(substitute(op('xor', $a, $b), {a => const(0)})), '(0 ^ b)', 'substitution');
ok(!eval { evaluate($a, {}); 1 }, 'missing value rejected');
ok(!eval { op('and', $a); 1 }, 'arity checked');
ok(!eval { op('atleast', 4, $a, $b); 1 }, 'threshold checked');
ok(!eval { validate({op => 'var', name => 'x', extra => 1}); 1 }, 'unknown fields rejected');
done_testing;
