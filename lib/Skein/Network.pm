package Skein::Network;
use 5.020;
use strict;
use warnings;
use Skein::Model;
use Skein::Engine;
use Skein::Expr qw(const var op);
use Skein::Rat qw(probability text);
use Skein::Util qw(check_keys identifier integer boolean deep_copy);

sub new {
    my ($class, $input) = @_;
    check_keys($input,[qw(name title vertices edges domains source target directed)],
        [qw(vertices edges source target)],'network');
    my $spec = deep_copy($input);
    $spec->{name} //= 'network';
    $spec->{title} //= 'Paths share more than endpoints';
    $spec->{directed} = boolean($spec->{directed} // 0);
    $spec->{domains} //= [];
    identifier($spec->{name},'network name');
    die "network vertices must be an array\n" unless ref($spec->{vertices}) eq 'ARRAY';
    integer(scalar @{$spec->{vertices}},'network vertex count',2,12);
    die "network edges must be an array\n" unless ref($spec->{edges}) eq 'ARRAY';
    integer(scalar @{$spec->{edges}},'network edge count',0,256);
    die "network domains must be an array\n" unless ref($spec->{domains}) eq 'ARRAY';
    integer(scalar @{$spec->{domains}},'network domain count',0,64);
    my %vertices;
    for my $vertex (@{$spec->{vertices}}) {
        identifier($vertex,'network vertex');
        die "duplicate network vertex '$vertex'\n" if $vertices{$vertex}++;
    }
    for my $role (qw(source target)) {
        identifier($spec->{$role},"network $role");
        die "unknown network $role\n" unless $vertices{$spec->{$role}};
    }
    my %domains;
    for my $domain (@{$spec->{domains}}) {
        check_keys($domain,[qw(name p cost)],[qw(name p)],'fault domain');
        identifier($domain->{name},'fault domain name');
        die "duplicate fault domain\n" if $domains{$domain->{name}}++;
        $domain->{p} = text(probability($domain->{p}));
        $domain->{cost} = integer($domain->{cost} // 10,'domain repair cost',0,1_000_000);
    }
    my %edges;
    for my $edge (@{$spec->{edges}}) {
        check_keys($edge,[qw(name from to p domains cost)],[qw(name from to p)],'network edge');
        identifier($edge->{name},'network edge name');
        die "duplicate network edge\n" if $edges{$edge->{name}}++;
        for my $role (qw(from to)) {
            identifier($edge->{$role},'edge endpoint');
            die "unknown edge endpoint\n" unless $vertices{$edge->{$role}};
        }
        die "network self edge is redundant\n" if $edge->{from} eq $edge->{to};
        $edge->{p} = text(probability($edge->{p}));
        $edge->{cost} = integer($edge->{cost} // 1,'edge repair cost',0,1_000_000);
        $edge->{domains} //= [];
        die "edge domains must be an array\n" unless ref($edge->{domains}) eq 'ARRAY';
        my %seen;
        for my $domain (@{$edge->{domains}}) {
            identifier($domain,'edge fault domain');
            die "unknown edge fault domain\n" unless $domains{$domain};
            die "duplicate edge fault domain\n" if $seen{$domain}++;
        }
    }
    return bless {spec => $spec},$class;
}

sub spec { return deep_copy($_[0]{spec}) }

sub _or {
    my (@args) = @_;
    return const(0) unless @args;
    my $result = shift @args;
    $result = op('or',$result,$_) for @args;
    return $result;
}

sub model {
    my ($self) = @_;
    return $self->{model} if $self->{model};
    my $spec = $self->{spec};
    my (@noise,@nodes,@repairs,@sensors);
    my (%failures,%domains,%direct);
    my %index;
    my $vertices = $spec->{vertices};
    $index{$vertices->[$_]} = $_ for 0 .. $#$vertices;
    for my $i (0 .. $#{$spec->{domains}}) {
        my $domain = $spec->{domains}[$i];
        my $u = "domain_noise_$i";
        my $node = "domain_failed_$i";
        push @noise,{name => $u,p => $domain->{p}};
        push @nodes,{name => $node,expr => var($u)};
        push @repairs,{name => "isolate_domain_$i",node => $node,value => 0,cost => $domain->{cost}};
        push @sensors,{name => "read_domain_$i",expr => var($node),cost => 1};
        $domains{$domain->{name}} = $node;
    }
    for my $i (0 .. $#{$spec->{edges}}) {
        my $edge = $spec->{edges}[$i];
        my $u = "edge_noise_$i";
        my $node = "edge_failed_$i";
        push @noise,{name => $u,p => $edge->{p}};
        my @causes = (var($u),map { var($domains{$_}) } @{$edge->{domains}});
        push @nodes,{name => $node,expr => _or(@causes)};
        push @repairs,{name => "restore_edge_$i",node => $node,value => 0,cost => $edge->{cost}};
        push @sensors,{name => "read_edge_$i",expr => var($node),cost => 1};
        $failures{$edge->{name}} = $node;
        my ($from,$to) = @index{$edge->{from},$edge->{to}};
        push @{$direct{"$from,$to"}},op('not',var($node));
        push @{$direct{"$to,$from"}},op('not',var($node)) unless $spec->{directed};
    }
    my %reach;
    for my $i (0 .. $#$vertices) {
        for my $j (0 .. $#$vertices) {
            my $name = "reach_0_${i}_$j";
            my $expr = $i == $j ? const(1) : _or(@{$direct{"$i,$j"} // []});
            push @nodes,{name => $name,expr => $expr};
            $reach{"$i,$j"} = $name;
        }
    }
    # Floyd-Warshall is expanded into a DAG of immutable stages. Cyclic
    # physical networks therefore introduce no cyclic structural equations.
    for my $k (0 .. $#$vertices) {
        my %next;
        for my $i (0 .. $#$vertices) {
            for my $j (0 .. $#$vertices) {
                my $name = 'reach_' . ($k+1) . "_${i}_$j";
                my $via = op('and',var($reach{"$i,$k"}),var($reach{"$k,$j"}));
                push @nodes,{name => $name,expr => op('or',var($reach{"$i,$j"}),$via)};
                $next{"$i,$j"} = $name;
            }
        }
        %reach = %next;
    }
    my ($s,$t) = @index{$spec->{source},$spec->{target}};
    push @nodes,{name => 'connected',expr => var($reach{"$s,$t"})},
        {name => 'outage',expr => op('not',var('connected'))};
    my @queries = ({name => 'baseline',event => var('outage')},
        {name => 'connected',event => var('connected')});
    $self->{model} = Skein::Model->new({name => $spec->{name},title => $spec->{title},
        noise => \@noise,nodes => \@nodes,queries => \@queries,
        repairs => \@repairs,sensors => \@sensors});
    $self->{mapping} = {edges => \%failures,domains => \%domains};
    return $self->{model};
}

sub mapping {
    my ($self) = @_;
    $self->model;
    return deep_copy($self->{mapping});
}

sub connected {
    my ($self, $noise, $interventions) = @_;
    $interventions //= {};
    my $model = $self->model;
    $model->validate_interventions($interventions);
    # The independent checker evaluates edge causes directly and runs BFS.
    # Interventions on internal reachability equations are intentionally
    # excluded because they do not describe physical edge changes.
    my %allowed = map { $_ => 1 } (values %{$self->{mapping}{edges}},values %{$self->{mapping}{domains}});
    die "physical network checker only accepts edge or domain interventions\n"
        if grep { !$allowed{$_} } keys %$interventions;
    my %domain_failed;
    for my $i (0 .. $#{$self->{spec}{domains}}) {
        my $domain = $self->{spec}{domains}[$i];
        my $name = $self->{mapping}{domains}{$domain->{name}};
        die "missing domain noise\n" unless exists $noise->{"domain_noise_$i"};
        $domain_failed{$domain->{name}} = exists($interventions->{$name})
            ? boolean($interventions->{$name}) : boolean($noise->{"domain_noise_$i"});
    }
    my %adjacency;
    for my $i (0 .. $#{$self->{spec}{edges}}) {
        my $edge = $self->{spec}{edges}[$i];
        my $name = $self->{mapping}{edges}{$edge->{name}};
        die "missing edge noise\n" unless exists $noise->{"edge_noise_$i"};
        my $failed = boolean($noise->{"edge_noise_$i"});
        $failed ||= $domain_failed{$_} for @{$edge->{domains}};
        $failed = boolean($interventions->{$name}) if exists $interventions->{$name};
        next if $failed;
        push @{$adjacency{$edge->{from}}},$edge->{to};
        push @{$adjacency{$edge->{to}}},$edge->{from} unless $self->{spec}{directed};
    }
    my @queue = ($self->{spec}{source});
    my %seen;
    while (@queue) {
        my $v = shift @queue;
        next if $seen{$v}++;
        return 1 if $v eq $self->{spec}{target};
        push @queue,@{$adjacency{$v} // []};
    }
    return 0;
}

sub verify {
    my ($self, %options) = @_;
    require Skein::Oracle;
    my $model = $self->model;
    my $engine = Skein::Engine->new($model);
    my $root = $engine->compiler->expression(var('connected'),$options{interventions} // {});
    my $oracle = Skein::Oracle->new($model,max_variables => $options{max_variables} // 16);
    my $worlds = $oracle->each_assignment(sub {
        my ($noise,$mass,$index) = @_;
        my $symbolic = $engine->compiler->bdd->evaluate($root,$noise);
        die "network reachability mismatch at world $index\n"
            unless $symbolic == $self->connected($noise,$options{interventions});
    });
    return {verified => 1,worlds => $worlds,method => 'independent physical BFS'};
}

sub profile {
    my ($self, %options) = @_;
    my $model = $self->model;
    my $engine = Skein::Engine->new($model,%options);
    return {model_digest => $model->digest,spec => $self->spec,mapping => $self->mapping,
        results => $engine->solve_all,stats => $engine->compiler->stats};
}

1;
