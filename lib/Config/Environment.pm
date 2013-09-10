# ABSTRACT: Application Configuration via Environment Variables
package Config::Environment;

use utf8;

use Moo;
use Hash::Flatten ();
use Hash::Merge   ();

# VERSION

=head1 SYNOPSIS

    use Config::Environment;

    my $conf = Config::Environment->new('myapp');
    my $conn = $conf->param('db.1.conn' => 'dbi:mysql:dbname=foobar');
    my $user = $conf->param('db.1.user'); # via $ENV{MYAPP_DB_1_USER} or undef
    my $pass = $conf->param('db.1.pass'); # via $ENV{MYAPP_DB_1_PASS} or undef

    or

    my $info = $conf->param('db.1');
    say $info->{conn}; # outputs dbi:mysql:dbname=foobar
    say $info->{user}; # outputs the value of $ENV{MYAPP_DB_1_USER}
    say $info->{pass}; # outputs the value of $ENV{MYAPP_DB_1_PASS}

    likewise ...

    $conf->param('server' => {node => ['10.10.10.02', '10.10.10.03']});

    creates the following environment variables and assignments

    $ENV{MYAPP_SERVER_NODE_1} = '10.10.10.02';
    $ENV{MYAPP_SERVER_NODE_2} = '10.10.10.03';

    ... and the configuration can be retrieved using any of the following

    $conf->param('server');
    $conf->param('server.node');
    $conf->param('server.node.1');
    $conf->param('server.node.2');

    or

    my ($node1, $node2) = $conf->params(qw(server.node.1 server.node.2));

=head1 DESCRIPTION

Config::Environment is an interface for managing application configuration using
environment variables as a backend. Using environment variables as a means of
application configuration is a great way of controlling which parts of your
application configuration gets hard-coded and shipped with your codebase (and
which parts do not). Using environment variables, application configuration can
be set at the system, user, and/or application levels and easily overridden.

=cut

sub BUILDARGS {
    my ($class, @args) = @_;

    unshift @args, 'domain' if $args[0] && $#args == 0;
    return {@args};
}

sub BUILD {
    my ($self) = @_;
    my $dom = lc $self->domain;

    $self->{snapshot} = { map {$_ => $ENV{$_}} grep { /^$dom\_/i } keys %ENV };
    return $self->load({%ENV}) if $self->autoload;
}

=attribute autoload

The autoload attribute contains a boolean value which determines whether
the global ENV hash will be sourced during instantiation. This attribute is
set to true by default.

=cut

has autoload => (
    is       => 'ro',
    required => 0,
    default  => 1
);

=attribute domain

The domain attribute contains the environment variable prefix used as context
to differentiate between other environment variables.

=cut

has domain => (
    is       => 'ro',
    required => 1
);

=attribute lifecycle

The lifecycle attribute contains a boolean value which if true restricts any
environment variables changes to life of the class instance. This attribute
is set to false by default.

=cut

has lifecycle => (
    is       => 'ro',
    required => 0,
    default  => 0
);

=attribute mirror

The mirror attribute contains a boolean value which if true copies any
configuration assignments to the corresponding environment variables. This
attribute is set to true by default.

=cut

has mirror => (
    is       => 'rw',
    required => 0,
    default  => 1
);

=attribute override

The override attribute contains a boolean value which determines whether
parameters corresponding to an existing environment variable can have it's
value overridden. This attribute is set to true by default.

=cut

has override => (
    is       => 'rw',
    required => 0,
    default  => 1
);

=method load

The load method expects a hashref which it parses and generates environment
variables from whether the exist or not and registers the formatted environment
structure. This method is called automatically on instantiation using the global
ENV hash as an argument.

    $self->load($hash);

=cut

sub load {
    my ($self, $hash) = @_;
    my $dom = lc $self->domain;
    my $env = { map {$_ => $hash->{$_}} grep { /^$dom\_/i } keys %{$hash} };
    my $reg = $self->{registry} //= {env => {}, map => {}};
    my $map = $reg->{map};

    for my $key (sort keys %{$env}) {
        my $value = delete $env->{$key};

        $key =~ s/_/./g;
        $key =~ s/^$dom\.//gi;

        my $hash = {lc $key => $value};

        if (ref $value) {
            if ('ARRAY' eq ref $value) {
                my $i = 0;
                $value = { map { ++$i => $_ } @{$value} };
            }

            $hash = Hash::Flatten->new->flatten($value);

            for my $refkey (keys %{$hash}) {
                (my $newref = $refkey) =~ s/(\w):(\d)/"$1.".($2+1)/gpe;
                $hash->{lc "$key.$newref"} = delete $hash->{$refkey};
            }
        }

        $map = Hash::Merge->new('RIGHT_PRECEDENT')->merge(
            $map => Hash::Flatten->new->unflatten($hash)
        );

        if ($self->mirror) {
            while (my($key, $val) = each(%{$hash})) {
                $ENV{$self->to_env_key($key)} = $val;
            }
        }
    }

    $reg->{map} = $map;

    return $self;
}

=method param

The param method expects a key which it uses to locate the corresponding
environment variable in the registered data structure. The key uses dot-notation
to traverse hierarchical data in the registry. This method will return undefined
if no element can be found matching the query. The method can also be used to
set environment variables by passing an additional argument as the value in the
form of a scalar, arrayref or hashref.

    my $item = $self->param($key);
    my $item = $self->param($key => $value);

=cut

sub param {
    my ($self, $key, $val) = @_;

    return unless defined $key;

    my $dom = $self->domain;

    $key = $self->to_dom_key($key);
    $key =~ s/^$dom(\.)?//;

    if (@_ > 2) {
        unless (exists $ENV{$self->to_env_key($key)} && ! $self->override) {
            $self->load({$self->to_env_key($key) => $val});
            $self->{registry}{env}{$key} = $val;
        }
    }

    if (exists $self->{registry}{env}{$key}) {
        return $self->{registry}{env}{$key};
    }
    else {
        my $node  = $self->{registry}{map};
        my @steps = split /\./, $key;
        for (my $i=0; $i<@steps; $i++) {
            my $step = $steps[$i];
            if (exists $node->{$step}) {
                if ($i<@steps && 'HASH' ne ref $node) {
                    return undef;
                }
                $node = $node->{$step};
            }
            else {
                return undef;
            }
        }
        return $self->{registry}{env}{$key} = $node;
    }

    return;
}

=method params

The params method expects a list of keys which are used to locate the
corresponding environment variables in the registered data structure. The keys
use dot-notation to traverse hierarchical data in the registry and return a list
of corresponding values in order specified. This method returns a list in
list-context, otherwise it returns the first element found of the list of
queries specified.

    my $item  = $self->params(@list_of_keys);
    my @items = $self->params(@list_of_keys);

=cut

sub params {
    my ($self, @keys) = @_;
    my @vals = map { $self->param($_) } @keys;
    return wantarray ? @vals : $vals[0];
}

=method environment

The environment method returns a hashref representing all environment variables
specific to the instantiated object's domain and instance.

    my $environment = $self->environment;

=cut

sub environment {
    my ($self) = @_;
    my $map = Hash::Flatten->new->flatten($self->{registry}{map});

    for my $key (keys %{$map}) {
        $map->{$self->to_env_key($key)} = delete $map->{$key};
    }

    return $map;
}

=method subdomain

The subdomain method returns a copy of the class instance with a modified domain
reference for easier access to nested configuration keys.

    my $db  = $self->subdomain('db');
    my $db1 = $db->subdomain('1');

    $db1->param('conn' => $connstring);
    $db1->param('user' => $username);
    $db1->param('pass' => $password);

=cut

sub subdomain {
    my ($self, $key) = @_;
    my $dom  = $self->domain;
    my $copy = ref($self)->new(
        autoload  => 0,
        override  => $self->override,
        lifecycle => $self->lifecycle,
        mirror    => $self->mirror,
        domain    => $dom
    );

    ($copy->{subdomain} = $self->to_dom_key($key)) =~ s/^$dom(\.)?//;
    $copy->{registry} = $self->{registry};

    return $copy;
}

sub to_dom_key {
    my ($self, $key) = @_;
    my $dom = $self->domain;

    $key =~ s/^$dom//;

    my @prefix = ($dom);
    push @prefix, $self->{subdomain} if defined $self->{subdomain};

    return lc join '.', @prefix, split /_/, $key;
}

sub to_env_key {
    my ($self, $key) = @_;
    my $dom = $self->domain;

    $key =~ s/^$dom//;

    return uc join '_', $dom, split /\./, $key
}

sub DESTROY {
    my ($self) = @_;

    if ($self->lifecycle) {
        my $environment = $self->environment;
        my $snapshot    = $self->{snapshot};

        delete $ENV{$_} for grep { ! exists $snapshot->{$_} } keys %{$environment};
        $ENV{$_} = $snapshot->{$_} for keys %{$snapshot};
    }
}

1;
