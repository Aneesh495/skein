use strict;
use warnings;
use Test::More;
use Skein::Model;
use Skein::Engine;
use Skein::Planner;

my $model = Skein::Model->from_text(<<'MODEL');
noise ua ~ 1/2;
noise ub ~ 1/2;
node a = ua;
node b = ub;
node outage = a | b;
query q = P(outage);
repair fix_a = a=0 cost 2;
repair fix_b = b=0 cost 3;
repair worsen = a=1 cost 1;
MODEL
my $planner = Skein::Planner->new(Skein::Engine->new($model));
my $plan = $planner->plan('q', budget => 5);
is($plan->{status}, 'optimal', 'complete plan');
is_deeply($plan->{selected}{actions}, [qw(fix_a fix_b)], 'synergistic repairs selected');
is($plan->{selected}{probability}, '0', 'repairs eliminate failure');
is_deeply([map { [$_->{cost}, $_->{probability}] } @{$plan->{frontier}}],
    [[0, '3/4'], [2, '1/2'], [5, '0']], 'exact Pareto frontier');
ok($plan->{stats}{conflicts} > 0, 'contradictory repairs excluded');
my $target = $planner->plan('q', target => '1/2', budget => 4);
is($target->{selected}{cost}, 2, 'cheapest target plan');
is($planner->plan('q', target => 0, budget => 4)->{status}, 'target_unreachable', 'unreachable distinguished');
my $required = $planner->plan('q', required => ['fix_b'], forbidden => ['fix_a'], budget => 5);
is_deeply($required->{selected}{actions}, ['fix_b'], 'repair constraints');
is($planner->plan('q', required => ['fix_b'], budget => 1)->{status}, 'infeasible', 'infeasible budget');
ok(!eval { $planner->plan('q', required => ['fix_a'], forbidden => ['fix_a']); 1 }, 'inconsistent constraints rejected');
ok(!eval { Skein::Planner->new(Skein::Engine->new($model), max_states => 1)->plan('q'); 1 }, 'search limit fails without partial optimum');
done_testing;
