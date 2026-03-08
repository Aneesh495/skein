package Skein::PolicyOracle;
use 5.020;
use strict;
use warnings;
use Skein::Oracle;
use Skein::Expr qw(const evaluate);
use Skein::Rat qw(rat zero one add mul divr compare text is_zero);
use Skein::Util qw(integer canonical_json deep_copy);

# This reference solver contains no BDD, factor or repair-planner dependency.
# Its belief states are explicit sets of source-world indices. It exhausts
# stopping actions and sensor choices in each positive-mass belief state.
sub new {
    my ($class, $model, %options) = @_;
    return bless {model=>$model,max_variables=>integer($options{max_variables}//8,
        'policy oracle variable limit',0,12),max_states=>integer($options{max_states}//10_000,
        'policy oracle state limit',1,1_000_000)},$class;
}

sub solve {
    my ($self, $input, %options) = @_;
    my $model = $self->{model};
    $input = $model->query($input) unless ref($input);
    my $query = deep_copy($input);
    $model->validate_query($query);
    die "policy oracle requires a factual starting world\n" if keys %{$query->{interventions}};
    die "policy oracle requires factual evidence\n" if exists($query->{evidence})
        && canonical_json($query->{evidence}) ne canonical_json(const(1));
    my $budget = integer($options{budget}//10,'policy oracle budget',0,1_000_000);
    my $loss = rat($options{failure_loss}//100);
    die "policy oracle failure loss must be positive\n" unless compare($loss,0)>0;
    my $sensors = $model->sensors;
    my $repairs = $model->repairs;
    die "policy oracle sensor limit exceeded\n" if @$sensors>6;
    die "policy oracle repair limit exceeded\n" if @$repairs>10;
    my @worlds;
    my $oracle = Skein::Oracle->new($model,max_variables=>$self->{max_variables},
        max_worlds=>2 ** $self->{max_variables});
    my $population = zero();
    $oracle->each_assignment(sub {
        my ($noise,$mass,$index) = @_;
        my $factual = $model->world($noise,{});
        return if is_zero($mass) || !evaluate($query->{factual}//const(1),$factual);
        my @readings = map { evaluate($_->{expr},$factual) } @$sensors;
        push @worlds,{noise=>{%$noise},mass=>$mass,readings=>\@readings,index=>$index};
        $population=add($population,$mass);
    });
    die "impossible evidence in policy oracle\n" if is_zero($population);
    my @actions;
    for my $mask (0 .. 2 ** @$repairs-1) {
        my %interventions;
        my @names;
        my $cost=0;
        my $conflict=0;
        for my $i (0 .. $#$repairs) {
            next unless ($mask>>$i)&1;
            my $repair=$repairs->[$i];
            $conflict=1 if exists($interventions{$repair->{node}})
                && $interventions{$repair->{node}} != $repair->{value};
            $interventions{$repair->{node}}=$repair->{value};
            $cost += $repair->{cost};
            push @names,$repair->{name};
        }
        next if $conflict || $cost>$budget;
        my @outcomes = map { evaluate($query->{event},$model->world($_->{noise},\%interventions)) } @worlds;
        push @actions,{cost=>$cost,names=>\@names,outcomes=>\@outcomes};
    }
    my %memo;
    my $states=0;
    my $search;
    $search=sub {
        my ($indices,$remaining,$available)=@_;
        my $key=canonical_json([$indices,$remaining,$available]);
        return $memo{$key} if exists $memo{$key};
        die "policy oracle state limit exceeded\n" if ++$states>$self->{max_states};
        my $mass=zero();
        $mass=add($mass,$worlds[$_]{mass}) for @$indices;
        die "policy oracle entered a zero-mass belief\n" if is_zero($mass);
        my $best;
        for my $action (@actions) {
            next if $action->{cost}>$remaining;
            my $failure=zero();
            for my $index (@$indices) {
                $failure=add($failure,$worlds[$index]{mass}) if $action->{outcomes}[$index];
            }
            my $risk=divr($failure,$mass);
            my $objective=add($action->{cost},mul($loss,$risk));
            next if $best && compare($objective,$best->{expected_loss})>=0;
            $best={kind=>'repair',actions=>[@{$action->{names}}],expected_loss=>text($objective),
                expected_risk=>text($risk),expected_cost=>"$action->{cost}"};
        }
        die "policy oracle has no stopping action\n" unless $best;
        for my $sensor_index (@$available) {
            my $sensor=$sensors->[$sensor_index];
            next if $sensor->{cost}>$remaining;
            my @partitions = ([],[]);
            push @{$partitions[$worlds[$_]{readings}[$sensor_index]]},$_ for @$indices;
            next unless @{$partitions[0]} && @{$partitions[1]};
            my @next = grep { $_!=$sensor_index } @$available;
            my $objective=rat($sensor->{cost});
            my $cost=rat($sensor->{cost});
            my $risk=zero();
            for my $partition (@partitions) {
                my $branch_mass=zero();
                $branch_mass=add($branch_mass,$worlds[$_]{mass}) for @$partition;
                my $weight=divr($branch_mass,$mass);
                my $child=$search->($partition,$remaining-$sensor->{cost},\@next);
                $objective=add($objective,mul($weight,$child->{expected_loss}));
                $cost=add($cost,mul($weight,$child->{expected_cost}));
                $risk=add($risk,mul($weight,$child->{expected_risk}));
            }
            next if compare($objective,$best->{expected_loss})>=0;
            $best={kind=>'sensor',sensor=>$sensor->{name},expected_loss=>text($objective),
                expected_risk=>text($risk),expected_cost=>text($cost)};
        }
        $memo{$key}=$best;
        return $best;
    };
    my $result=$search->([0 .. $#worlds],$budget,[0 .. $#$sensors]);
    return {schema=>'skein.policy_reference/1',model_digest=>$model->digest,%$result,
        positive_worlds=>scalar @worlds,states=>$states,
        evidence_probability=>text($population),budget=>$budget,failure_loss=>text($loss),
        method=>'explicit source-world belief states and exhaustive stopping actions'};
}

1;
