use strict;
use warnings;
use Test::More;
use Skein::Generate;
use Skein::Model;
use Skein::Engine;
use Skein::Policy;
use Skein::PolicyOracle;

my $model=Skein::Model->from_file('examples/diagnosis.sk');
for my $budget (0,1,5,6,10,12) {
    for my $loss (1,10,100) {
        my $policy=Skein::Policy->new(Skein::Engine->new($model))->synthesize('baseline',
            budget=>$budget,failure_loss=>$loss);
        my $reference=Skein::PolicyOracle->new($model)->solve('baseline',budget=>$budget,failure_loss=>$loss);
        is($policy->{tree}{expected_loss},$reference->{expected_loss},"diagnosis optimum budget=$budget loss=$loss");
    }
}
my $generator=Skein::Generate->new(seed=>'policy-reference');
for my $i (0 .. 15) {
    my $model=$generator->model(noise=>$i%4,nodes=>3);
    my $policy=Skein::Policy->new(Skein::Engine->new($model));
    my $result=$policy->synthesize('baseline',budget=>4,failure_loss=>10);
    my $reference=Skein::PolicyOracle->new($model)->solve('baseline',budget=>4,failure_loss=>10);
    is($result->{tree}{expected_loss},$reference->{expected_loss},"generated adaptive optimum $i");
    ok($policy->verify($result)->{verified},"generated complete replay $i");
}
my $gated=Skein::Model->from_text(<<'MODEL');
noise u ~ 1/3;
noise v ~ 1/4;
node x = u;
node y = v;
node fail = x & !y;
query baseline = P(fail) factual(x | y);
repair clear = x=0 cost 3;
repair toggle = y=1 cost 2;
sensor alarm = x ^ y cost 0;
MODEL
my $p=Skein::Policy->new(Skein::Engine->new($gated));
my $r=$p->synthesize('baseline',budget=>3,failure_loss=>20);
my $ref=Skein::PolicyOracle->new($gated)->solve('baseline',budget=>3,failure_loss=>20);
is($r->{tree}{expected_loss},$ref->{expected_loss},'conditional belief and zero-cost sensor optimum');
ok($p->verify($r)->{verified},'conditional policy replay');
eval { Skein::PolicyOracle->new($model,max_states=>1)->solve('baseline',budget=>12) };
like($@,qr/state limit/,'reference search refuses partial optimum');
done_testing;
