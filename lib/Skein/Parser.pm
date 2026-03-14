package Skein::Parser;
use 5.020;
use strict;
use warnings;
use Skein::Lexer;
use Skein::Expr qw(validate const var);
use Skein::Util qw(integer);

my %PRECEDENCE = ('<->' => 1, '->' => 2, '|' => 3, '^' => 4, '&' => 5);
my %OPERATOR = ('<->' => 'eq', '->' => 'implies', '|' => 'or', '^' => 'xor', '&' => 'and');

sub new {
    my ($class, $source, %options) = @_;
    return bless {
        lexer => Skein::Lexer->new($source, %options),
        depth => 0,
        expression_nodes => 0,
    }, $class;
}

sub expression {
    my ($self, $minimum) = @_;
    $minimum //= 1;
    $self->{lexer}->error('expression nesting limit exceeded') if ++$self->{depth} > 96;
    $self->{lexer}->error('expression size limit exceeded') if ++$self->{expression_nodes} > 100_000;
    my $left = $self->_prefix;
    while (1) {
        my $next = $self->{lexer}->peek->{value};
        last unless exists($PRECEDENCE{$next}) && $PRECEDENCE{$next} >= $minimum;
        $self->{lexer}->next;
        my $right_minimum = $PRECEDENCE{$next} + ($next eq '->' ? 0 : 1);
        my $right = $self->expression($right_minimum);
        $left = { op => $OPERATOR{$next}, args => [$left, $right] };
    }
    --$self->{depth};
    return $left;
}

sub _prefix {
    my ($self) = @_;
    my $lexer = $self->{lexer};
    if ($lexer->accept('!')) {
        return { op => 'not', args => [$self->expression(6)] };
    }
    if ($lexer->accept('(')) {
        my $result = $self->expression;
        $lexer->expect(')');
        return $result;
    }
    my $token = $lexer->next;
    if ($token->{type} eq 'number') {
        $lexer->error('Boolean literal must be 0 or 1', $token)
            unless $token->{value} eq '0' || $token->{value} eq '1';
        return const($token->{value});
    }
    $lexer->error('expected Boolean expression', $token) unless $token->{type} eq 'name';
    my $name = $token->{value};
    return var($name) unless $lexer->accept('(');
    $lexer->error("unknown expression function '$name'", $token)
        unless $name eq 'ite' || $name eq 'atleast' || $name eq 'exactly';
    my $threshold;
    if ($name ne 'ite') {
        $threshold = $lexer->expect_type('number')->{value};
        my $valid = eval { integer($threshold, 'threshold', 0, 4096); 1 };
        $lexer->error($@,$token) unless $valid;
    }
    my @args;
    if ($name eq 'ite') {
        push @args, $self->expression;
        while ($lexer->accept(',')) {
            push @args, $self->expression;
        }
    } elsif ($lexer->accept(',')) {
        push @args, $self->expression;
        while ($lexer->accept(',')) {
            push @args, $self->expression;
        }
    }
    $lexer->expect(')');
    my $result = { op => $name, args => \@args };
    $result->{k} = 0 + $threshold if defined $threshold;
    my $valid = eval { validate($result); 1 };
    $lexer->error($@,$token) unless $valid;
    return $result;
}

sub parse_expression {
    my ($class, $source, %options) = @_;
    my $self = $class->new($source, %options);
    my $result = $self->expression;
    $self->{lexer}->expect_type('eof');
    validate($result);
    return $result;
}

sub _assignments {
    my ($self) = @_;
    my $lexer = $self->{lexer};
    my %assignments;
    $lexer->expect('(');
    unless ($lexer->accept(')')) {
        while (1) {
            my $name = $lexer->expect_type('name')->{value};
            $lexer->error("duplicate intervention '$name'") if exists $assignments{$name};
            $lexer->expect('=');
            my $token = $lexer->expect_type('number');
            $lexer->error('intervention value must be 0 or 1', $token)
                unless $token->{value} eq '0' || $token->{value} eq '1';
            $assignments{$name} = 0 + $token->{value};
            last if $lexer->accept(')');
            $lexer->expect(',');
        }
    }
    return \%assignments;
}

sub model {
    my ($self) = @_;
    my $lexer = $self->{lexer};
    my $result = {
        schema => 'skein.model/1', name => 'untitled', title => '',
        noise => [], nodes => [], queries => [], repairs => [], sensors => [], intervals => {},
    };
    my %single;
    while ($lexer->peek->{type} ne 'eof') {
        my $declaration = $lexer->expect_type('name');
        my $kind = $declaration->{value};
        if ($kind eq 'model' || $kind eq 'title') {
            $lexer->error("duplicate $kind declaration", $declaration) if $single{$kind}++;
            $result->{$kind eq 'model' ? 'name' : 'title'} =
                $lexer->expect_type($kind eq 'model' ? 'name' : 'string')->{value};
        } elsif ($kind eq 'noise') {
            my $name = $lexer->expect_type('name')->{value};
            $lexer->expect('~');
            my $p = $lexer->expect_type('number')->{value};
            push @{$result->{noise}}, { name => $name, p => $p };
        } elsif ($kind eq 'node') {
            my $name = $lexer->expect_type('name')->{value};
            $lexer->expect('=');
            $self->{expression_nodes} = 0;
            my $expr = $self->expression;
            validate($expr);
            push @{$result->{nodes}}, { name => $name, expr => $expr };
        } elsif ($kind eq 'query') {
            my $name = $lexer->expect_type('name')->{value};
            $lexer->expect('=');
            $lexer->expect('P');
            $lexer->expect('(');
            $self->{expression_nodes} = 0;
            my $query = { name => $name, event => $self->expression, interventions => {} };
            $lexer->expect(')');
            my %clauses;
            while ($lexer->peek->{value} ne ';') {
                my $clause = $lexer->expect_type('name');
                my $keyword = $clause->{value};
                $lexer->error("unknown query clause '$keyword'", $clause)
                    unless $keyword eq 'given' || $keyword eq 'factual' || $keyword eq 'do';
                $lexer->error("duplicate '$keyword' clause", $clause) if $clauses{$keyword}++;
                if ($keyword eq 'do') {
                    $query->{interventions} = $self->_assignments;
                } else {
                    $lexer->expect('(');
                    $query->{$keyword eq 'given' ? 'evidence' : 'factual'} = $self->expression;
                    $lexer->expect(')');
                }
            }
            push @{$result->{queries}}, $query;
        } elsif ($kind eq 'repair') {
            my $name = $lexer->expect_type('name')->{value};
            $lexer->expect('=');
            my $node = $lexer->expect_type('name')->{value};
            $lexer->expect('=');
            my $value = $lexer->expect_type('number')->{value};
            $lexer->expect('cost');
            my $cost = $lexer->expect_type('number')->{value};
            push @{$result->{repairs}}, {name => $name, node => $node, value => $value, cost => $cost};
        } elsif ($kind eq 'sensor') {
            my $name = $lexer->expect_type('name')->{value};
            $lexer->expect('=');
            $self->{expression_nodes} = 0;
            my $expr = $self->expression;
            $lexer->expect('cost');
            my $cost = $lexer->expect_type('number')->{value};
            push @{$result->{sensors}}, {name => $name, expr => $expr, cost => $cost};
        } elsif ($kind eq 'interval') {
            my $name = $lexer->expect_type('name')->{value};
            $lexer->error("duplicate interval '$name'") if exists $result->{intervals}{$name};
            $lexer->expect('=');
            $lexer->expect('[');
            my $low = $lexer->expect_type('number')->{value};
            $lexer->expect(',');
            my $high = $lexer->expect_type('number')->{value};
            $lexer->expect(']');
            $result->{intervals}{$name} = [$low, $high];
        } elsif ($kind eq 'order') {
            $lexer->error('duplicate order declaration') if $single{order}++;
            my @names = ($lexer->expect_type('name')->{value});
            push @names, $lexer->expect_type('name')->{value} while $lexer->accept(',');
            $result->{order} = \@names;
        } else {
            $lexer->error("unknown declaration '$kind'", $declaration);
        }
        $lexer->expect(';');
    }
    return $result;
}

sub parse {
    my ($class, $source, %options) = @_;
    return $class->new($source, %options)->model;
}

1;
