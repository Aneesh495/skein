package Skein::Campaign;
use 5.020;
use strict;
use warnings;
use Time::HiRes qw(time);
use Skein::Generate;
use Skein::Source;
use Skein::Engine;
use Skein::Oracle;
use Skein::Eliminate;
use Skein::Certificate;
use Skein::Witness;
use Skein::Planner;
use Skein::Sample;
use Skein::Causal;
use Skein::BDD;
use Skein::ZDD;
use Skein::Cutsets;
use Skein::Spectrum;
use Skein::Polynomial;
use Skein::Expr qw(const var evaluate);
use Skein::BDD::Count qw(weighted_count gradient);
use Skein::BDD::Transform qw(restrict quantify compose transfer sat_count export_diagram import_diagram);
use Skein::Rat qw(zero one add subr mul divr text compare is_zero);
use Skein::Util qw(integer digest canonical_json write_json write_text);

sub new {
    my ($class, %options) = @_;
    my $seed = $options{seed} // 'skein.campaign/1';
    return bless {seed => $seed,generator => Skein::Generate->new(seed => $seed),
        assertions => 0,worlds => 0,queries => 0,checks => {},receipt => digest($seed),
        failure_directory => $options{failure_directory},progress => $options{progress}},$class;
}

sub _assert {
    my ($self, $condition, $label) = @_;
    ++$self->{assertions};
    ++$self->{checks}{$label};
    die "campaign invariant failed: $label\n" unless $condition;
    return;
}

sub _equal {
    my ($self, $left, $right, $label) = @_;
    my $same = !ref($left) && !ref($right)
        ? (!defined($left) && !defined($right) ? 1
            : defined($left) && defined($right) && "$left" eq "$right")
        : canonical_json($left) eq canonical_json($right);
    $self->_assert($same,$label);
}

sub _receipt {
    my ($self, $value) = @_;
    $self->{receipt} = digest([$self->{receipt},$value]);
}

sub _solve {
    my ($backend, $query) = @_;
    my $result = eval { $backend->solve($query) };
    return {status => 'defined',map { $_ => $result->{$_} } qw(probability numerator denominator)} unless $@;
    die $@ unless $@ =~ /impossible evidence/;
    return {status => 'impossible_evidence'};
}

sub _case {
    my ($self, $index, %options) = @_;
    my $model = $self->{generator}->model(noise => $index % 7,nodes => 3+$index%6);
    $self->{current} = {phase => 'causal_models',index => $index,model => $model->raw,
        source => Skein::Source->emit($model)};
    my $reparsed = Skein::Model->from_text($self->{current}{source});
    $self->_equal($reparsed->digest,$model->digest,'source identity');
    my $engine = Skein::Engine->new($model);
    my $reordered = Skein::Engine->new($model,order => [reverse @{$model->order}]);
    my $oracle = Skein::Oracle->new($model);
    my $factor = Skein::Eliminate->new($model);
    my @records;
    for my $name (@{$model->query_names}) {
        $self->{current}{query} = $name;
        my $query = $model->query($name);
        my $actual = _solve($engine,$query);
        my $direct = _solve($oracle,$query);
        my $eliminated = _solve($factor,$query);
        $self->_equal($actual,$direct,'BDD against source worlds');
        $self->_equal($actual,$eliminated,'BDD against sparse factors');
        $self->_equal($actual,_solve($reordered,$query),'variable order independence');
        ++$self->{queries};
        $self->{worlds} += 2 ** @{$model->noise_names};
        push @records,{name => $name,%$actual};
        next unless $actual->{status} eq 'defined';
        my $roots = $engine->compiler->query($query);
        my $certificate = Skein::Certificate->create($engine,$query);
        my $checked = Skein::Certificate->verify($model,$certificate);
        $self->_equal($checked->{probability},$actual->{probability},'complete truth-function certificate');
        my $ledger = $oracle->solve($query,ledger => 1);
        my $posteriors = $engine->noise_posterior($query);
        for my $noise (@{$model->noise_names}) {
            my $mass = zero();
            for my $row (@{$ledger->{ledger}}) {
                $mass = add($mass,$row->{mass}) if $row->{evidence} && $row->{noise}{$noise};
            }
            $self->_equal($posteriors->{$noise},text(divr($mass,$actual->{denominator})),
                'noise posterior against ledger');
        }
        my $sample = Skein::Sample->new($engine,seed => "$self->{seed}:$index:$name");
        for my $noise (@{$sample->draws($query,3)}) {
            my $factual = $model->world($noise,{});
            my $target = $model->world($noise,$query->{interventions});
            $self->_assert(evaluate($query->{factual} // const(1),$factual)
                && evaluate($query->{evidence} // const(1),$target),'posterior draw satisfies both worlds');
            $self->_assert(!is_zero($model->assignment_mass($noise)),'posterior draw has positive source mass');
        }
        my $witness = Skein::Witness->maximum_assignment($engine->compiler->bdd,$roots->{numerator},$model->priors);
        my $reference = $oracle->maximum_world($query);
        $self->_equal(defined($witness) ? $witness->{mass} : undef,
            defined($reference) ? $reference->{mass} : undef,'complete MAP mass against enumeration');
    }
    my $baseline = $model->query('baseline');
    my $root = $engine->compiler->query($baseline)->{numerator};
    my $gradient = gradient($engine->compiler->bdd,$root,$model->priors);
    my $poly = Skein::Polynomial->from_bdd($engine->compiler->bdd,$root);
    $self->_equal(text($poly->evaluate($model->priors)),text($gradient->{mass}),'polynomial weighted mass');
    for my $noise (@{$model->noise_names}) {
        my %low = %{$model->priors};
        my %high = %low;
        $low{$noise} = '0';
        $high{$noise} = '1';
        my $a = $oracle->solve($baseline,priors => \%low)->{probability};
        my $b = $oracle->solve($baseline,priors => \%high)->{probability};
        $self->_equal(text($gradient->{derivatives}{$noise}),text(subr($b,$a)),
            'gradient against exact source endpoint difference');
        $self->_equal(text($poly->derivative($noise)->evaluate($model->priors)),
            text($gradient->{derivatives}{$noise}),'polynomial derivative');
    }
    my $spectrum = Skein::Spectrum->from_bdd($engine->compiler->bdd,$root);
    $self->_equal($spectrum->probability($model->priors),text($gradient->{mass}),'Walsh reconstruction under biased priors');
    $self->_equal($spectrum->reconstruct,[map { $_->{event} } @{$oracle->solve($baseline,ledger => 1)->{ledger}}],
        'spectral inverse source truth table') if canonical_json($engine->compiler->bdd->variables) eq canonical_json($model->noise_names);
    if ($options{deep}) {
        $self->_check_planner($engine,$oracle,$baseline);
        my $treatment = $model->node_names->[0];
        my $causal = Skein::Causal->new($engine);
        my $response = $causal->response($treatment,$baseline->{event});
        $self->_assert($causal->verify_response($response)->{verified},'paired causal response source check');
    }
    $engine->compiler->bdd->assert_invariants;
    my $record = {index => $index,model_digest => $model->digest,
        noise => scalar @{$model->noise_names},queries => \@records,
        bdd_nodes => $engine->compiler->bdd->node_count,order => $engine->compiler->bdd->variables};
    $self->_receipt($record);
    return $record;
}

sub _check_planner {
    my ($self, $engine, $oracle, $query) = @_;
    my $repairs = $engine->model->repairs;
    my $budget = 4;
    my $best;
    for my $mask (0 .. 2 ** @$repairs - 1) {
        my ($cost,%interventions);
        $cost = 0;
        for my $i (0 .. $#$repairs) {
            next unless ($mask >> $i) & 1;
            $cost += $repairs->[$i]{cost};
            $interventions{$repairs->[$i]{node}} = $repairs->[$i]{value};
        }
        next if $cost > $budget;
        my $p = $oracle->solve({event => $query->{event},interventions => \%interventions})->{probability};
        $best = $p if !defined($best) || compare($p,$best) < 0;
    }
    my $plan = Skein::Planner->new($engine)->plan($query,budget => $budget);
    $self->_equal($plan->{selected}{probability},$best,'repair optimum against source subsets');
}

sub _truth_root {
    my ($bdd, $table, $rank, $mask) = @_;
    return $table->[$mask] if $rank == @{$bdd->variables};
    my $low = _truth_root($bdd,$table,$rank+1,$mask);
    my $high = _truth_root($bdd,$table,$rank+1,$mask | (1 << $rank));
    return $bdd->mk($rank,$low,$high);
}

sub _cube_holds {
    my ($table, $cube, $variables) = @_;
    for my $mask (0 .. $#$table) {
        my $matches = 1;
        for my $i (0 .. $#$variables) {
            next unless exists $cube->{$variables->[$i]};
            $matches = 0 if (($mask >> $i) & 1) != $cube->{$variables->[$i]};
        }
        return 0 if $matches && !$table->[$mask];
    }
    return 1;
}

sub _brute_primes {
    my ($table, $variables) = @_;
    my @primes;
    for my $code (0 .. 3 ** @$variables - 1) {
        my $rest = $code;
        my %cube;
        for my $name (@$variables) {
            my $digit = $rest % 3;
            $rest = int($rest/3);
            $cube{$name} = $digit - 1 if $digit;
        }
        next unless _cube_holds($table,\%cube,$variables);
        my $prime = 1;
        for my $name (keys %cube) {
            my %smaller = %cube;
            delete $smaller{$name};
            $prime = 0 if _cube_holds($table,\%smaller,$variables);
        }
        push @primes,canonical_json(\%cube) if $prime;
    }
    return [sort @primes];
}

sub _truth_case {
    my ($self, $function) = @_;
    my @variables = qw(a b c);
    my @table = map { ($function >> $_) & 1 } 0 .. 7;
    $self->{current} = {phase => 'complete_three_variable_functions',function => $function,table => \@table};
    my $bdd = Skein::BDD->new(\@variables);
    my $root = _truth_root($bdd,\@table,0,0);
    my $count = 0;
    $count += $_ for @table;
    $self->_equal(sat_count($bdd,$root)->bstr,"$count",'exact satisfying assignment count');
    my $primes = Skein::Cutsets->new($bdd,$root)->prime_implicants;
    $self->_equal([sort map { canonical_json($_) } @$primes],_brute_primes(\@table,\@variables),
        'complete signed prime family against ternary enumeration');
    my ($copy,$roots) = import_diagram(export_diagram($bdd,[$root]));
    my $reversed = Skein::BDD->new([reverse @variables]);
    my $changed = transfer($bdd,$reversed,$root);
    my %mapping = (a => $bdd->variable('b'),b => $bdd->negate($bdd->variable('a')));
    my $composed = compose($bdd,$root,\%mapping);
    my %transforms;
    for my $i (0 .. 2) {
        my $name = $variables[$i];
        $transforms{$name} = [restrict($bdd,$root,{$name => 0}),restrict($bdd,$root,{$name => 1}),
            quantify($bdd,$root,[$name],'exists'),quantify($bdd,$root,[$name],'forall')];
    }
    for my $mask (0 .. 7) {
        my %values = map { $variables[$_] => (($mask >> $_) & 1) } 0 .. 2;
        $self->_equal($bdd->evaluate($root,\%values),$table[$mask],'BDD truth table');
        $self->_equal($copy->evaluate($roots->[0],\%values),$table[$mask],'serialized diagram semantics');
        $self->_equal($reversed->evaluate($changed,\%values),$table[$mask],'reordered diagram semantics');
        my $substituted = ($values{b}) | ((1-$values{a}) << 1) | ($values{c} << 2);
        $self->_equal($bdd->evaluate($composed,\%values),$table[$substituted],'parallel nonrecursive substitution');
        for my $i (0 .. 2) {
            my $low = $table[$mask & ~(1 << $i)];
            my $high = $table[$mask | (1 << $i)];
            my @expected = ($low,$high,$low || $high ? 1 : 0,$low && $high ? 1 : 0);
            for my $j (0 .. 3) {
                $self->_equal($bdd->evaluate($transforms{$variables[$i]}[$j],\%values),$expected[$j],
                    'cofactor and quantifier source truth');
            }
        }
    }
    my $spectrum = Skein::Spectrum->new(\@variables,\@table);
    $self->_equal($spectrum->reconstruct,\@table,'complete Boolean Walsh inversion');
    my $priors = {a => '1/3',b => '1/4',c => '2/5'};
    $self->_equal($spectrum->probability($priors),text(weighted_count($bdd,$root,$priors)),
        'complete Boolean weighted spectral reconstruction');
    $bdd->assert_invariants;
    $self->_receipt({function => $function,root => $root,primes => $primes});
    return;
}

sub _family_sets {
    my ($mask) = @_;
    my @sets;
    for my $set (0 .. 7) {
        next unless ($mask >> $set) & 1;
        push @sets,[map { (qw(a b c))[$_] } grep { ($set >> $_) & 1 } 0 .. 2];
    }
    return \@sets;
}

sub _family_mask {
    my ($zdd, $root) = @_;
    my %index = (a => 0,b => 1,c => 2);
    my $mask = 0;
    for my $set (@{$zdd->sets($root)}) {
        my $bits = 0;
        $bits |= 1 << $index{$_} for @$set;
        $mask |= 1 << $bits;
    }
    return $mask;
}

sub _family_case {
    my ($self, $a, $b) = @_;
    $self->{current} = {phase => 'set_families',left => $a,right => $b};
    my $zdd = Skein::ZDD->new([qw(a b c)]);
    my $left = $zdd->from_sets(_family_sets($a));
    my $right = $zdd->from_sets(_family_sets($b));
    $self->_equal(_family_mask($zdd,$zdd->union($left,$right)),$a | $b,'ZDD union source family');
    $self->_equal(_family_mask($zdd,$zdd->intersection($left,$right)),$a & $b,'ZDD intersection source family');
    $self->_equal(_family_mask($zdd,$zdd->difference($left,$right)),$a & ~$b,'ZDD difference source family');
    my ($product,$minimal,$nonsuper) = (0,0,0);
    for my $x (0 .. 7) {
        next unless ($a >> $x) & 1;
        my ($has_smaller,$has_subset) = (0,0);
        for my $y (0 .. 7) {
            $product |= 1 << ($x | $y) if ($b >> $y) & 1;
            next unless ($x & $y) == $y;
            $has_smaller = 1 if $x != $y && (($a >> $y) & 1);
            $has_subset = 1 if ($b >> $y) & 1;
        }
        $minimal |= 1 << $x unless $has_smaller;
        $nonsuper |= 1 << $x unless $has_subset;
    }
    $self->_equal(_family_mask($zdd,$zdd->product($left,$right)),$product,'ZDD set-union product source family');
    $self->_equal(_family_mask($zdd,$zdd->minimal($left)),$minimal,'ZDD antichain minimization source family');
    $self->_equal(_family_mask($zdd,$zdd->exclude_supersets($left,$right)),$nonsuper,'ZDD superset exclusion source family');
    my $count = scalar @{_family_sets($a)};
    $self->_equal($zdd->count($left)->bstr,"$count",'ZDD family cardinality');
    $zdd->assert_invariants;
    $self->_receipt([$a,$b,$product,$minimal,$nonsuper]);
}

sub run {
    my ($self, %options) = @_;
    my $cases = integer($options{cases} // 16,'campaign case count',0,10_000);
    my $functions = integer($options{functions} // 256,'campaign function count',0,256);
    my $families = integer($options{families} // 256,'campaign family pairs',0,65_536);
    my $start = time;
    my @records;
    my $ok = eval {
        local $SIG{__WARN__} = sub { die "unexpected campaign warning: $_[0]" };
        for my $i (0 .. $cases - 1) {
            push @records,$self->_case($i,deep => $options{deep} // 1);
            $self->{progress}->('models',$i+1,$cases) if $self->{progress};
        }
        for my $i (0 .. $functions - 1) {
            $self->_truth_case($i);
            $self->{progress}->('functions',$i+1,$functions) if $self->{progress};
        }
        for my $i (0 .. $families - 1) {
            my $a = $i % 256;
            my $b = $families == 65_536 ? int($i/256) : $self->{generator}{rng}->integer(256);
            $self->_family_case($a,$b);
            $self->{progress}->('families',$i+1,$families) if $self->{progress};
        }
        1;
    };
    if (!$ok) {
        my $error = $@ || 'unknown campaign failure';
        if (defined $self->{failure_directory}) {
            my $path = $self->{failure_directory};
            write_json("$path/failure.json",{seed => $self->{seed},error => $error,
                case => $self->{current},assertions => $self->{assertions}});
            write_text("$path/failure.sk",$self->{current}{source}) if $self->{current}{source};
        }
        die $error;
    }
    return {schema => 'skein.campaign/1',seed => $self->{seed},passed => 1,
        cases => $cases,functions => $functions,family_pairs => $families,queries => $self->{queries},
        source_world_evaluations => $self->{worlds},assertions => $self->{assertions},
        checks => {%{$self->{checks}}},receipt => $self->{receipt},records => \@records,
        elapsed_seconds => 0+(sprintf '%.6f',time-$start)};
}

1;
