use strict;
use warnings;
use Test::More;
use Skein::RNG;
use Skein::Model;
use Skein::Engine;
use Skein::Sample;
use Skein::Rat qw(rat);

my $left = Skein::RNG->new(1234);
my $right = Skein::RNG->new(1234);
is(unpack('H*', $left->bytes(100)), unpack('H*', $right->bytes(100)), 'deterministic byte stream');
for my $bound (1, 2, 3, 1000, '10000000000000000000000000000000001') {
    my $sample = $left->below($bound);
    ok($sample->bcmp(0) >= 0 && $sample->bcmp($bound) < 0, 'arbitrary precision random bound');
}
is($left->bernoulli(0), 0, 'certain false');
is($left->bernoulli(1), 1, 'certain true');
my $model = Skein::Model->from_text('noise a ~ 1/3; noise b ~ 1/4; node x = a ^ b; query q = P(a) given(x);');
my $engine = Skein::Engine->new($model);
my $sampler = Skein::Sample->new($engine, seed => 42);
my $samples = $sampler->draws('q', 50);
for my $noise (@$samples) {
    is($noise->{a} ^ $noise->{b}, 1, 'posterior samples preserve XOR dependence');
}
my $replay = Skein::Sample->new($engine, seed => 42)->draws('q', 50);
is_deeply($samples, $replay, 'posterior draws replay exactly');
my $estimate = Skein::Sample->new($engine, seed => 712)->estimate('q', 1000);
my $exact = rat($estimate->{exact_probability})->numify;
ok(abs($estimate->{estimate} - $exact) < 0.08, 'seeded Monte Carlo agrees with exact answer');
ok($estimate->{interval_95}[0] <= $estimate->{estimate} && $estimate->{interval_95}[1] >= $estimate->{estimate}, 'Wilson interval encloses estimate');
ok(!eval { $left->below(0); 1 }, 'zero random bound rejected');
done_testing;
