package Skein::Workload;
use 5.020;
use strict;
use warnings;
use Math::BigInt;
use Skein::Model;
use Skein::Expr qw(var const op);
use Skein::Rat qw(rat zero one probability add subr mul divr text);
use Skein::Util qw(integer);

sub _power {
    my ($base, $exponent) = @_;
    my $value = rat($base);
    $value->bpow($exponent);
    return $value;
}

sub independent {
    my ($class, $kind, $size, %options) = @_;
    integer($size,'workload size',1,2048);
    die "unknown independent workload\n" unless $kind =~ /\A(?:series|parallel|parity|threshold)\z/;
    my $p = probability($options{p} // '1/100');
    my @noise = map { {name => "u$_",p => text($p)} } 0 .. $size-1;
    my @nodes;
    my $event;
    my $expected;
    if ($kind eq 'threshold') {
        my $k = integer($options{k} // int($size/2),'workload threshold',0,$size);
        $event = op('atleast',$k,map { var($_->{name}) } @noise);
        $expected = zero();
        my $choose = Math::BigInt->new(1);
        for my $i (0 .. $size) {
            if ($i >= $k) {
                my $term = mul($choose->bstr,mul(_power($p,$i),_power(subr(1,$p),$size-$i)));
                $expected = add($expected,$term);
            }
            $choose->bmul($size-$i)->bdiv($i+1) if $i < $size;
        }
    } else {
        my $operator = $kind eq 'series' ? 'or' : $kind eq 'parallel' ? 'and' : 'xor';
        push @nodes,{name => 'prefix_0',expr => var('u0')};
        for my $i (1 .. $size-1) {
            push @nodes,{name => "prefix_$i",expr => op($operator,var('prefix_' . ($i-1)),var("u$i"))};
        }
        $event = var('prefix_' . ($size-1));
        $expected = $kind eq 'series' ? subr(1,_power(subr(1,$p),$size))
            : $kind eq 'parallel' ? _power($p,$size)
            : divr(subr(1,_power(subr(1,mul(2,$p)),$size)),2);
    }
    return {name => $kind . '_' . $size,expected => text($expected),
        model => Skein::Model->new({name => $kind . '_' . $size,
            noise => \@noise,nodes => \@nodes,order => [map { $_->{name} } @noise],
            queries => [{name => 'baseline',event => $event}]})};
}

sub shared_domains {
    my ($class, $groups, $replicas, %options) = @_;
    integer($groups,'workload domains',1,64);
    integer($replicas,'workload replicas',1,32);
    my $p = probability($options{failure} // '1/50');
    my $domain = probability($options{domain} // '1/100');
    my $global = probability($options{global} // '1/1000');
    my @noise = ({name => 'global_noise',p => text($global)});
    my @nodes = ({name => 'global_failed',expr => var('global_noise')});
    my @domain_nodes;
    for my $g (0 .. $groups-1) {
        push @noise,{name => "domain_noise_$g",p => text($domain)};
        push @nodes,{name => "domain_failed_$g",expr => var("domain_noise_$g")};
        my @replica_nodes;
        for my $r (0 .. $replicas-1) {
            my $u = "replica_noise_${g}_$r";
            my $n = "replica_failed_${g}_$r";
            push @noise,{name => $u,p => text($p)};
            push @nodes,{name => $n,expr => op('or',var("domain_failed_$g"),var($u))};
            push @replica_nodes,var($n);
        }
        my $n = "group_failed_$g";
        push @nodes,{name => $n,expr => op('atleast',$replicas,@replica_nodes)};
        push @domain_nodes,var($n);
    }
    push @nodes,{name => 'all_groups_failed',expr => op('atleast',$groups,@domain_nodes)};
    push @nodes,{name => 'outage',expr => op('or',var('global_failed'),var('all_groups_failed'))};
    my $group_probability = add($domain,mul(subr(1,$domain),_power($p,$replicas)));
    my $expected = add($global,mul(subr(1,$global),_power($group_probability,$groups)));
    my @order = map { $_->{name} } @noise;
    return {name => "domains_${groups}x$replicas",expected => text($expected),
        model => Skein::Model->new({name => "domains_${groups}x$replicas",
            noise => \@noise,nodes => \@nodes,order => \@order,
            queries => [{name => 'baseline',event => var('outage')}]})};
}

sub multiplexer {
    my ($class, $address_bits, %options) = @_;
    integer($address_bits,'multiplexer address bits',1,8);
    my @address = map { {name => "address_$_",p => '1/2'} } 0 .. $address_bits-1;
    my @data = map { {name => "data_$_",p => ($_ % 2 ? '2/3' : '1/3')} } 0 .. 2 ** $address_bits - 1;
    my @nodes;
    my @current = map { $_->{name} } @data;
    for my $bit (0 .. $address_bits-1) {
        my @next;
        for my $pair (0 .. @current/2-1) {
            my $name = "mux_${bit}_$pair";
            push @nodes,{name => $name,expr => op('ite',var("address_$bit"),
                var($current[2*$pair+1]),var($current[2*$pair]))};
            push @next,$name;
        }
        @current = @next;
    }
    my @order = $options{data_first} ? (map { $_->{name} } @data,@address)
        : (map { $_->{name} } @address,@data);
    return {name => 'mux_' . $address_bits . ($options{data_first} ? '_data_first' : '_address_first'),
        expected => '1/2',model => Skein::Model->new({name => 'multiplexer',
            noise => [@address,@data],nodes => \@nodes,order => \@order,
            queries => [{name => 'baseline',event => var($current[0])}]})};
}

sub suite {
    my ($class, %options) = @_;
    my $size = integer($options{size} // 256,'benchmark scale',8,512);
    return [$class->independent('series',$size),$class->independent('parallel',$size),
        $class->independent('parity',$size,p => '1/3'),
        $class->independent('threshold',32,p => '1/3',k => 16),
        $class->shared_domains(16,4),$class->multiplexer(6),
        $class->multiplexer(5,data_first => 1)];
}

1;
