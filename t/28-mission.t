use strict;
use warnings;
use Test::More;
use Skein::Mission;
use Skein::Markov;
use Skein::Engine;
use Skein::Eliminate;
use Skein::Oracle;

my $mission = Skein::Mission->new({name => 'disk', horizon => 3,
    processes => [{name => 'disk', failure => '1/10', repair => '1/2'}]});
my $profile = $mission->profile;
my $markov = Skein::Markov->new([qw(healthy failed)], [['9/10','1/10'],['1/2','1/2']]);
my $trajectory = $markov->trajectory(3);
my $passage = $markov->first_passage(['failed'],3);
for my $tick (0 .. 3) {
    is($profile->{times}[$tick]{failure}, $trajectory->[$tick]{distribution}{failed}, 'causal unroll vs matrix transition');
    is($profile->{times}[$tick]{first_passage}, $passage->{times}[$tick]{mass}, 'causal unroll vs absorbing first passage');
}
is($profile->{expected_uptime}, $markov->expected_reward({healthy => 1},3)->{total}, 'causal uptime vs Markov reward');
my $model = $mission->build;
my $engine = Skein::Engine->new($model);
is($engine->solve('ever')->{probability}, Skein::Oracle->new($model)->solve('ever')->{probability}, 'mission exhaustive oracle');
is($engine->solve('terminal')->{probability}, Skein::Eliminate->new($model)->solve('terminal')->{probability}, 'mission factor backend');
my $shared = Skein::Mission->new({horizon => 2, threshold => 2, persistent_shock => '1/10',
    processes => [{name => 'a',failure => 0,repair => 1},{name => 'b',failure => 0,repair => 1}]});
is($shared->profile->{terminal_failure}, '1/10', 'persistent shared failure survives repair');
my $zero = Skein::Mission->new({horizon => 0,processes => [{name => 'a',initial => '1/3',failure => 0,repair => 1}]});
is($zero->profile->{ever_failure}, '1/3', 'zero-horizon initial failure');
ok(!eval { Skein::Mission->new({horizon => 65,processes => []}); 1 }, 'mission horizon bound');
done_testing;
