package Skein::Benchmark;
use 5.020;
use strict;
use warnings;
use Config;
use Time::HiRes qw(time);
use Skein::Workload;
use Skein::Engine;
use Skein::Rat qw(compare);
use Skein::Util qw(integer digest);

sub run {
    my ($class, %options) = @_;
    my $repetitions = integer($options{repetitions} // 3,'benchmark repetitions',1,20);
    my $max_nodes = integer($options{max_nodes} // 20_000,'benchmark node limit',2,250_000);
    my $suite = Skein::Workload->suite(size => $options{size} // 256);
    my @cases;
    for my $case (@$suite) {
        my @runs;
        for my $repetition (1 .. $repetitions) {
            my ($user_before,$system_before) = times;
            my $start = time;
            my $engine = Skein::Engine->new($case->{model},max_nodes => $max_nodes);
            my $result = eval { $engine->solve('baseline') };
            my $error = $@;
            my $elapsed = time-$start;
            my ($user_after,$system_after) = times;
            if ($error) {
                die $error unless $case->{name} =~ /data_first/ && $error =~ /limit exceeded/;
                push @runs,{status => 'resource_bound',error => $error,
                    elapsed_seconds => $elapsed,cpu_seconds => $user_after+$system_after-$user_before-$system_before,
                    stats => $engine->compiler->stats};
            } else {
                die "benchmark closed-form mismatch in $case->{name}\n"
                    unless compare($result->{probability},$case->{expected}) == 0;
                push @runs,{status => 'exact',probability => $result->{probability},
                    elapsed_seconds => $elapsed,cpu_seconds => $user_after+$system_after-$user_before-$system_before,
                    stats => $engine->compiler->stats,reachable_nodes => $result->{reachable_nodes}};
            }
            $options{progress}->($case->{name},$repetition,$repetitions) if $options{progress};
        }
        push @cases,{name => $case->{name},model_digest => $case->{model}->digest,
            noise => scalar @{$case->{model}->noise_names},equations => scalar @{$case->{model}->node_names},
            order => $case->{model}->order,expected => $case->{expected},runs => \@runs};
    }
    return {schema => 'skein.benchmark/1',repetitions => $repetitions,max_nodes => $max_nodes,
        environment => {perl => "$^V",os => $^O,arch => $Config{archname},
            integer_bits => 8*$Config{ivsize},bigint_backend => Math::BigInt->config->{lib}},
        methodology => 'Fresh manager per repetition; compilation and exact counting included; no warmup removed.',
        interpretation => 'Local measurements for specified synthetic workloads, not cross-language or hardware comparisons.',
        cases => \@cases};
}

1;
