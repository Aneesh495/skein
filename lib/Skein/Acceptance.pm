package Skein::Acceptance;
use 5.020;
use strict;
use warnings;
use Config;
use Cwd qw(getcwd);
use File::Find qw(find);
use File::Spec;
use TAP::Harness;
use Time::HiRes qw(time);
use Skein::Evidence;
use Skein::Campaign;
use Skein::Benchmark;
use Skein::Model;
use Skein::Engine;
use Skein::Oracle;
use Skein::Eliminate;
use Skein::Certificate;
use Skein::Network;
use Skein::Mission;
use Skein::Policy;
use Skein::PolicyOracle;
use Skein::Report;
use Skein::Source;
use Skein::Util qw(write_json write_text decode_json_file read_text integer);

sub _files {
    my ($directory, $pattern) = @_;
    my @paths;
    find({no_chdir=>1,wanted=>sub {
        push @paths,$File::Find::name if -f $File::Find::name && $File::Find::name =~ $pattern;
    }},$directory);
    return [sort @paths];
}

sub lint {
    my ($class) = @_;
    my @files = ('README.md',@{_files('lib',qr/\.pm\z/)},@{_files('tools',qr/\.pl\z/)},
        @{_files('t',qr/\.t\z/)},@{_files('docs',qr/\.md\z/)},@{_files('examples',qr/\.sk\z/)});
    my @modules;
    for my $file (@files) {
        my $source = read_text($file);
        die "forbidden punctuation in $file\n" if index($source,chr(0x2014)) >= 0;
        next unless $file =~ /\Alib\/(.+\.pm)\z/;
        my $module = $1;
        die "missing strictness in $file\n" unless $source =~ /^use strict;/m && $source =~ /^use warnings;/m;
        require $module;
        push @modules,$module;
    }
    return {passed=>1,modules=>scalar @modules,files=>scalar @files};
}

sub tests {
    my ($class, %options) = @_;
    my $paths = _files('t',qr/\.t\z/);
    die "no tests discovered\n" unless @$paths;
    my $path = $options{log} // '.runtime/tests.tap.txt';
    write_text($path,'');
    open my $log,'>:encoding(UTF-8)',$path or die "cannot open test log: $!\n";
    my @results;
    my $harness = TAP::Harness->new({lib=>['lib'],verbosity=>1,stdout=>$log,
        callbacks => {after_test=>sub {
            my ($job,$parser) = @_;
            push @results,{file=>$job->[0],assertions=>scalar($parser->tests_run),
                passed=>$parser->has_problems ? 0 : 1,exit=>$parser->exit,
                parse_errors=>[$parser->parse_errors]};
            print "Test $job->[0]: " . ($parser->has_problems ? 'FAIL' : 'PASS') . "\n";
        }}});
    my $start = time;
    my $aggregate = $harness->runtests(@$paths);
    close $log or die "cannot close test log\n";
    die "test suite failed; inspect $path\n" if $aggregate->has_errors || !$aggregate->total;
    return {passed=>1,files=>scalar(@$paths),assertions=>$aggregate->total,
        records=>\@results,elapsed_seconds=>time-$start};
}

sub examples {
    my ($class, %options) = @_;
    my @records;
    my @certificates;
    for my $path (@{_files('examples',qr/\.sk\z/)}) {
        my $model = Skein::Model->from_file($path);
        my $copy = Skein::Model->from_text(Skein::Source->emit($model));
        die "example source round trip failed\n" unless $copy->digest eq $model->digest;
        my $engine = Skein::Engine->new($model);
        my @results;
        for my $name (@{$model->query_names}) {
            my $actual = $engine->solve($name);
            my $direct = Skein::Oracle->new($model)->solve($name);
            my $factor = Skein::Eliminate->new($model)->solve($name);
            for my $field (qw(probability numerator denominator)) {
                die "example backend disagreement: $path $name $field\n"
                    unless $actual->{$field} eq $direct->{$field} && $actual->{$field} eq $factor->{$field};
            }
            my $certificate = Skein::Certificate->create($engine,$name);
            Skein::Certificate->verify($model,$certificate);
            push @certificates,{path=>$path,query=>$name,certificate=>$certificate};
            push @results,{query=>$name,map { $_=>$actual->{$_} } qw(probability numerator denominator)};
        }
        my $report = Skein::Report->new($engine)->html;
        die "report requires external resources\n" if $report =~ /(?:src|href)="https?:/ || $report =~ /<script\b/i;
        push @records,{path=>$path,model_digest=>$model->digest,results=>\@results,
            standalone_report=>1};
    }
    my $network = Skein::Network->new(decode_json_file('examples/bridge.json'));
    my $network_check = $network->verify;
    my $mission = Skein::Mission->new(decode_json_file('examples/mission.json'));
    my $mission_check = $mission->profile;
    my $diagnosis = Skein::Model->from_file('examples/diagnosis.sk');
    my $policy = Skein::Policy->new(Skein::Engine->new($diagnosis));
    my $decision = $policy->synthesize('baseline',budget=>12,failure_loss=>100);
    my $checked = $policy->verify($decision);
    my $reference = Skein::PolicyOracle->new($diagnosis)->solve('baseline',budget=>12,failure_loss=>100);
    die "diagnosis policy is not independently optimal\n"
        unless $reference->{expected_loss} eq $decision->{tree}{expected_loss};
    $checked->{optimality_reference}=$reference;
    return {passed=>1,models=>\@records,certificates=>\@certificates,
        physical_network=>$network_check,temporal_mission=>$mission_check,diagnosis=>$checked};
}

sub run {
    my ($class, $root, %options) = @_;
    my $previous = getcwd;
    $root = File::Spec->rel2abs($root);
    chdir $root or die "cannot enter project: $!\n";
    my $bundle;
    my $ok = eval {
        my $source = Skein::Evidence->source_manifest($root);
        my $start = time;
        my $lint = $class->lint;
        my $tests = $class->tests;
        my $examples = $class->examples;
        my $last = time;
        my $campaign = Skein::Campaign->new(seed=>$options{seed}//'skein.frozen/1',
            failure_directory=>'.runtime',progress=>sub {
                my ($phase,$done,$total) = @_;
                return if time-$last < 10 && $done != $total;
                print "Campaign $phase $done/$total\n";
                $last=time;
            })->run(cases=>$options{cases}//128,functions=>256,families=>$options{families}//2048);
        my $benchmark = Skein::Benchmark->run(repetitions=>$options{repetitions}//3,
            progress=>sub { print "Benchmark $_[0] $_[1]/$_[2]\n" });
        Skein::Evidence->verify_source($root,$source);
        $bundle = Skein::Evidence->bundle($source,{passed=>1,lint=>$lint,tests=>$tests,
            examples=>$examples,campaign=>$campaign,benchmark=>$benchmark,
            environment=>{perl=>"$^V",os=>$^O,arch=>$Config{archname}},
            elapsed_seconds=>time-$start});
        1;
    };
    my $error = $@;
    chdir $previous or die "cannot restore working directory: $!\n";
    die $error unless $ok;
    return $bundle;
}

sub verify {
    my ($class, $root, $bundle) = @_;
    my $result = Skein::Evidence->verify_bundle($root,$bundle);
    my $examples = $bundle->{payload}{data}{examples};
    die "acceptance examples missing\n" unless ref($examples) eq 'HASH' && $examples->{passed};
    my $certificates = $examples->{certificates};
    die "acceptance certificates missing\n" unless ref($certificates) eq 'ARRAY' && @$certificates;
    my $count = 0;
    for my $entry (@$certificates) {
        my $path = $entry->{path};
        die "invalid certificate source path\n" unless defined($path) && $path =~ /\Aexamples\/[A-Za-z0-9_-]+\.sk\z/;
        my $model = Skein::Model->from_file(File::Spec->catfile($root,split m{/},$path));
        Skein::Certificate->verify($model,$entry->{certificate});
        ++$count;
    }
    $result->{source_world_certificates}=$count;
    return $result;
}

1;
