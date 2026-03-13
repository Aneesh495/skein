use strict;
use warnings;
use Test::More;
use Skein::Generate;
use Skein::Model;
use Skein::Engine;
use Skein::Robust;
use Skein::Oracle;
use Skein::Expr qw(const evaluate var op substitute);
use Skein::Rat qw(zero one add subr mul divr text compare is_zero);
use Skein::Util qw(deep_copy canonical_json);

sub direct_masses {
    my ($model,$query,$priors)=@_;
    my ($n,$d)=(zero(),zero());
    my $names=$model->noise_names;
    for my $mask (0 .. 2 ** @$names-1) {
        my %noise=map { $names->[$_] => (($mask>>$_)&1) } 0 .. $#$names;
        my $factual=$model->world(\%noise,{});
        my $target=$model->world(\%noise,$query->{interventions});
        my $mass=$model->assignment_mass(\%noise,$priors);
        next unless evaluate($query->{factual}//const(1),$factual)
            && evaluate($query->{evidence}//const(1),$target);
        $d=add($d,$mass);
        $n=add($n,$mass) if evaluate($query->{event},$target);
    }
    return ($n,$d);
}

my $generator=Skein::Generate->new(seed=>'metamorphic');
for my $index (0 .. 19) {
    my $model=$generator->model(noise=>1+$index%4,nodes=>4);
    my $raw=$model->raw;
    $_->{p}='1/2' for @{$raw->{noise}};
    $raw->{intervals}={map { $_->{name}=>['1/4','3/4'] } @{$raw->{noise}}};
    $model=Skein::Model->new($raw);
    my $engine=Skein::Engine->new($model);
    my $reversed=deep_copy($raw);
    $reversed->{$_}=[reverse @{$reversed->{$_}}] for qw(noise nodes queries sensors repairs);
    is(Skein::Model->new($reversed)->digest,$model->digest,"declaration order does not change identity $index");
    for my $name (@{$model->query_names}) {
        my $query=$model->query($name);
        my ($n,$d)=direct_masses($model,$query,$model->priors);
        next if is_zero($d);
        my $sensitivity=$engine->sensitivity($query);
        for my $noise (@{$model->noise_names}) {
            my %low=%{$model->priors};
            my %high=%low;
            $low{$noise}=0;
            $high{$noise}=1;
            my ($n0,$d0)=direct_masses($model,$query,\%low);
            my ($n1,$d1)=direct_masses($model,$query,\%high);
            my $expected=divr(subr(mul(subr($n1,$n0),$d),mul($n,subr($d1,$d0))),mul($d,$d));
            is($sensitivity->{derivatives}{$noise},text($expected),"conditional quotient derivative $index/$name/$noise");
        }
        my $bounds=Skein::Robust->new($engine)->bounds($query);
        for my $trial (1 .. 5) {
            my %interior=map { $_ => (qw(1/4 1/3 1/2 2/3 3/4))[$generator->{rng}->integer(5)] } @{$model->noise_names};
            my ($ni,$di)=direct_masses($model,$query,\%interior);
            my $p=divr($ni,$di);
            ok(compare($p,$bounds->{minimum}{probability})>=0 && compare($p,$bounds->{maximum}{probability})<=0,
                "independent interior risk lies in exact corner bounds $index/$name/$trial");
        }
        my $posterior=$engine->noise_posterior($query);
        ok(!(grep { compare($_,0)<0 || compare($_,1)>0 } values %$posterior),"posterior probabilities bounded $index/$name");
    }
    my %mapping=map { $_ => var('renamed_' . $_) } (@{$model->noise_names},@{$model->node_names});
    my $renamed=deep_copy($raw);
    $_->{name}='renamed_' . $_->{name} for @{$renamed->{noise}};
    for my $node (@{$renamed->{nodes}}) {
        $node->{name}='renamed_' . $node->{name};
        $node->{expr}=substitute($node->{expr},\%mapping);
    }
    for my $query (@{$renamed->{queries}}) {
        $query->{$_}=substitute($query->{$_},\%mapping) for grep { exists $query->{$_} } qw(event evidence factual);
        $query->{interventions}={map { ('renamed_' . $_)=>$query->{interventions}{$_} } keys %{$query->{interventions}}};
    }
    $_->{node}='renamed_' . $_->{node} for @{$renamed->{repairs}};
    $_->{expr}=substitute($_->{expr},\%mapping) for @{$renamed->{sensors}};
    $renamed->{intervals}={map { ('renamed_' . $_)=>$raw->{intervals}{$_} } keys %{$raw->{intervals}}};
    $renamed->{order}=[map { 'renamed_' . $_ } @{$raw->{order}}];
    my $renamed_engine=Skein::Engine->new(Skein::Model->new($renamed));
    is($renamed_engine->solve('baseline')->{probability},$engine->solve('baseline')->{probability},
        "alpha-renaming preserves structural probability $index");
    my $mutated=$model->raw;
    $mutated->{noise}[0]{p}='0';
    is($engine->solve('baseline')->{probability},Skein::Engine->new(Skein::Model->new($raw))->solve('baseline')->{probability},
        "returned model data cannot mutate running engine $index");
}
done_testing;
