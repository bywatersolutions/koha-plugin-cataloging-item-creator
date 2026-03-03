package Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Auth;
use C4::Context;

use Koha::Account::Lines;
use Koha::Account;
use Koha::DateUtils qw(dt_from_string);
use Koha::Biblios;
use Koha::Libraries;
use Koha::Patron::Categories;
use Koha::Patron;
use Koha::Item;

use Cwd qw(abs_path);
use Data::Dumper;
use LWP::UserAgent;
use MARC::Record;
use Mojo::JSON qw(decode_json);
use URI::Escape qw(uri_unescape);
use Try::Tiny;
use Carp qw(longmess);

## Here we set our plugin version
our $VERSION         = "{VERSION}";
our $MINIMUM_VERSION = "{MINIMUM_VERSION}";

our $metadata = {
    name            => 'Auto-create Items on Record Creation',
    author          => 'Kyle M Hall',
    date_authored   => '2009-01-27',
    date_updated    => "1900-01-01",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Automatically create dummy items on new records to allow holds.'
};

sub new {
    my ($class, $args) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub after_biblio_action {
    my ($self, $params) = @_;

    my $action = $params->{action};
    my $biblio = $params->{biblio};
    my $biblio_id = $params->{biblio_id};

    warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Action: $action";
    warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Biblio ID: $biblio_id ( $biblio )";

    if ( $action eq 'delete' ) {
        warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Biblio is being deleted, skipping: $biblio_id";
        return;
    }

    # Check to see if we should do anything
    my $caller = $0;
    my $do_create = 0;
    for my $allowed_caller ("marc_ordering_process.pl", "addorderiso2709.pl", "-e") { # -e is from a one-shot cli, eg perl -MKoha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator -e 'Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator->new->after_biblio_action({ action => "create"})'
        if (index($caller, $allowed_caller) != -1) {
            $do_create = 1;
            warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - " .
                "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - $caller matched on $allowed_caller for Biblio $biblio_id";
        }
        else {
            warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - " .
                "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - $caller did not match on $allowed_caller for Biblio $biblio_id";
        }
    }
    return unless $do_create;

    if ( $biblio_id && !$biblio ) {
        warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Biblio not passed in for non-delete action, fetching from database...: ";

        $biblio = Koha::Biblios->find($biblio_id);

        unless ( $biblio ) {
            warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - biblio $biblio_id not found in database!";
        }
    }

    try {
        warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - " .
            "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Called from '$0' for Biblio $biblio_id";

        if ($do_create) {
            if ($biblio && $biblio->items->count == 0) {
                warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - " . "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Create item for biblio $biblio_id";
                $self->_create_item_for_biblio({ biblio => $biblio });
            }
            elsif (!$biblio) {
                warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - " . "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Biblio $biblio_id not found, falling back to todays imports";
                $self->create_items_for_today_vendor_imports();
            }
        }
    }
    catch {
        warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - caught error: $_: "
            . longmess("STACK TRACE");
    };
}

sub create_items_for_today_vendor_imports {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare(
        q{
SELECT import_batches.upload_timestamp,
       import_batches.file_name,
       import_biblios.matched_biblionumber,
       biblio.biblionumber
FROM   import_batches
       LEFT JOIN import_records USING ( import_batch_id )
       LEFT JOIN import_biblios USING ( import_record_id )
       LEFT JOIN biblio
              ON ( import_biblios.matched_biblionumber = biblio.biblionumber )
       LEFT JOIN items USING ( biblionumber )
WHERE  ( import_batches.file_name LIKE ?
          OR import_batches.file_name LIKE ? )
       AND DATE(import_batches.upload_timestamp) = CURDATE()
       AND items.itemnumber IS NULL
}
    );
    $sth->execute('%ingram%', '%vendor%');

    my $created = 0;
    while ( my $r = $sth->fetchrow_hashref ) {
        my $biblionumber = $r->{biblionumber} || $r->{matched_biblionumber};
        unless ($biblionumber) {
            next;
        }

        my $biblio = Koha::Biblios->find($biblionumber);
        next unless $biblio;

        my $item = $self->_create_item_for_biblio({
            biblio                    => $biblio,
            default_homebranch        => $self->retrieve_data('default_homebranch') || 'ADM',
            default_holdingbranch     => $self->retrieve_data('default_holdingbranch') || 'ADM',
            default_itype             => $self->retrieve_data('default_itype') || '960$y',
            skip_if_items_exist       => 1,
            log_context               => "file_name=$r->{file_name}, upload_timestamp=$r->{upload_timestamp}",
        });
        $created++ if $item;
    }

    warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - " .
        "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Created $created items from today's vendor imports";
    return $created;
}

sub _create_item_for_biblio {
    my ($self, $params) = @_;

    my $biblio = $params->{biblio};
    return unless $biblio;

    my $biblio_id = $biblio->id;

    if ( $params->{skip_if_items_exist} && $biblio->items->count ) {
        warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - " .
            "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Biblio $biblio_id has items, skipping";
        return;
    }

    my $default_homebranch    = $params->{default_homebranch} // $self->retrieve_data('default_homebranch');
    my $default_holdingbranch = $params->{default_holdingbranch} // $self->retrieve_data('default_holdingbranch');
    my $default_itype         = $params->{default_itype} // $self->retrieve_data('default_itype');

    if ( defined $default_itype && $default_itype =~ m/^\d\d\d\$\w$/ ) {
        my $record = $biblio->metadata->record;
        my ($field, $subfield) = split(/\$/, $default_itype);
        $default_itype = $record->subfield($field, $subfield);
        warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - " .
            "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Got itype of $default_itype for $field $subfield for Biblio $biblio_id";
    }

    my $data = {
        homebranch    => $default_homebranch,
        holdingbranch => $default_holdingbranch,
        itype         => $default_itype,
        biblionumber  => $biblio_id,
        notforloan    => "-1",
    };

    my $log_context = $params->{log_context} ? " [$params->{log_context}]" : '';
    warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - " .
        "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Adding item for Biblio $biblio_id $log_context: " . Data::Dumper::Dumper($data);

    my $item = Koha::Item->new($data)->store;
    $item->discard_changes();
    warn dt_from_string->strftime('%Y-%m-%dT%H:%M:%S') . " - " .
        "Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator - Item created for Biblio $biblio_id: " . Data::Dumper::Dumper($item->unblessed);

    return $item;
}

sub configure {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    unless ($cgi->param('save')) {
        my $template = $self->get_template({file => 'configure.tt'});

        $template->param(
            default_homebranch    => $self->retrieve_data('default_homebranch'),
            default_holdingbranch => $self->retrieve_data('default_holdingbranch'),
            default_itype         => $self->retrieve_data('default_itype'),
        );

        $self->output_html($template->output());
    }
    else {
        $self->store_data({
            default_homebranch    => $cgi->param('default_homebranch'),
            default_holdingbranch => $cgi->param('default_holdingbranch'),
            default_itype         => $cgi->param('default_itype'),
        });
        $self->go_home();
    }
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ($self, $args) = @_;

    return 1;
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ($self, $args) = @_;

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ($self, $args) = @_;

    return 1;
}

1;
