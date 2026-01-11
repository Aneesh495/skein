use strict;
use warnings;
use Test::More;
use Skein::Model;
use Skein::Rat qw(text);

my $source = 'model test; noise u ~ 1/3; node b = a | u; node a = !u; query q = P(b); repair r = a=0 cost 3;';
my $model = Skein::Model->from_text($source);
is_deeply($model->node_order, [qw(a b)], 'forward references topologically resolved');
is_deeply($model->world({u => 0}), {u => 0, a => 1, b => 1}, 'factual world');
is_deeply($model->world({u => 0}, {a => 0}), {u => 0, a => 0, b => 0}, 'internal intervention propagates');
is(text($model->assignment_mass({u => 1})), '1/3', 'exact assignment mass');
my $raw = $model->raw;
$raw->{noise}[0]{p} = '1';
is($model->priors->{u}, '1/3', 'raw copy does not mutate model');
my $again = Skein::Model->from_text('model test; node a = !u; noise u ~ 1/3; node b = a | u; repair r = a=0 cost 3; query q = P(b);');
is($model->digest, $again->digest, 'declaration order independent identity');
for my $bad (
    'noise u ~ 1/0;', 'noise u ~ 2;', 'noise u ~ 0; node u = 0;',
    'node a = b; node b = a;', 'node a = absent;',
    'noise u ~ 1/2; query q = P(u) do(u=0);',
    'noise u ~ 1/2; order nope;', 'noise u ~ 1/2; order u,u;',
    'noise u ~ 1/2; interval u = [3/4, 1];', 'noise u ~ 1/2; repair r = u=0 cost 3;',
) {
    ok(!eval { Skein::Model->from_text($bad); 1 }, 'invalid structural model rejected');
}
ok(!eval { $model->world({u => 0, other => 1}); 1 }, 'unknown noise assignment rejected');
ok(!eval { $model->world({}); 1 }, 'missing noise rejected');
done_testing;
