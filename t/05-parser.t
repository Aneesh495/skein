use strict;
use warnings;
use Test::More;
use Skein::Parser;
use Skein::Expr qw(evaluate render);

my $raw = Skein::Parser->parse(<<'MODEL');
model fleet;
title "Shared failure";
noise rack ~ 1/20;
noise disk ~ .01;
node lost = rack | disk;
query baseline = P(lost);
query repaired = P(lost) do(lost=0) factual(lost);
repair isolate = lost=0 cost 4;
interval rack = [1/100, 1/10];
order rack, disk;
MODEL
is($raw->{name}, 'fleet', 'model header');
is($raw->{noise}[0]{p}, '1/20', 'rational retained');
is($raw->{queries}[1]{interventions}{lost}, 0, 'intervention');
is($raw->{queries}[1]{factual}{name}, 'lost', 'factual evidence');
is_deeply($raw->{order}, [qw(rack disk)], 'variable order');
my $expr = Skein::Parser->parse_expression('a | b & !c');
is(render($expr), '(a | (b & !(c)))', 'operator precedence');
is(render(Skein::Parser->parse_expression('a -> b -> c')), '(a -> (b -> c))', 'right associative implication');
is(evaluate(Skein::Parser->parse_expression('atleast(2, a, b, c)'), {a => 1, b => 0, c => 1}), 1, 'threshold function');
is(evaluate(Skein::Parser->parse_expression('exactly(0)'), {}), 1, 'empty exact threshold');
for my $bad (
    'node x = a', 'node x = 2;', 'node x = magic(a);',
    'query q = P(x) do(x=0,x=1);', 'query q = P(x) given(x) given(x);',
    'model x; model y;', 'node x = ite(a,b);', 'unknown x;',
) {
    ok(!eval { Skein::Parser->parse($bad); 1 }, 'bad model syntax rejected');
}
ok(!eval { Skein::Parser->parse_expression('a b'); 1 }, 'trailing expression tokens rejected');
my $deep = '(' x 130 . 'a' . ')' x 130;
ok(!eval { Skein::Parser->parse_expression($deep); 1 }, 'deep expression fails explicitly');
done_testing;
