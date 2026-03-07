#!/usr/bin/perl

use Modern::Perl;
use Test::More tests => 6;
use Test::Warn;
use Test::MockModule;

use Koha::Database;
use Koha::Biblios;
use Koha::Items;
use t::lib::TestBuilder;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

$schema->storage->txn_begin;

use_ok('Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator');

my $plugin = Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator->new;

subtest 'after_biblio_action skips deletes' => sub {
    plan tests => 1;

    my $biblio = $builder->build_sample_biblio;
    my $item_count_before = Koha::Items->search({ biblionumber => $biblio->biblionumber })->count;

    warnings_exist {
        $plugin->after_biblio_action({
            action    => 'delete',
            biblio    => $biblio,
            biblio_id => $biblio->biblionumber,
        });
    } [ qr/Biblio is being deleted, skipping/ ],
      'Logs delete skip message';

    my $item_count_after = Koha::Items->search({ biblionumber => $biblio->biblionumber })->count;
    # Cannot use is() inside warnings_exist, so test after
    is( $item_count_after, $item_count_before, 'No items created on delete' );
};

subtest 'after_biblio_action checks caller' => sub {
    plan tests => 2;

    my $biblio = $builder->build_sample_biblio;

    {
        local $0 = '/some/random/script.pl';
        $plugin->after_biblio_action({
            action    => 'create',
            biblio    => $biblio,
            biblio_id => $biblio->biblionumber,
        });

        my $item_count = Koha::Items->search({ biblionumber => $biblio->biblionumber })->count;
        is( $item_count, 0, 'No items created when caller is not in allowed list' );
    }

    {
        local $0 = '/usr/share/koha/intranet/cgi-bin/cataloguing/addorderiso2709.pl';
        $plugin->after_biblio_action({
            action    => 'create',
            biblio    => $biblio,
            biblio_id => $biblio->biblionumber,
        });

        my $item_count = Koha::Items->search({ biblionumber => $biblio->biblionumber })->count;
        is( $item_count, 1, 'Item created when caller matches addorderiso2709.pl' );
    }
};

subtest '_create_item_for_biblio' => sub {
    plan tests => 7;

    my $library = $builder->build_object({ class => 'Koha::Libraries' });
    my $itemtype = $builder->build_object({ class => 'Koha::ItemTypes' });

    # Returns undef when no biblio
    my $result = $plugin->_create_item_for_biblio({});
    is( $result, undef, 'Returns undef when no biblio passed' );

    # Creates item with correct data
    my $biblio = $builder->build_sample_biblio;
    my $item = $plugin->_create_item_for_biblio({
        biblio                => $biblio,
        default_homebranch    => $library->branchcode,
        default_holdingbranch => $library->branchcode,
        default_itype         => $itemtype->itemtype,
    });

    ok( $item, 'Returns item object' );
    is( $item->homebranch,    $library->branchcode, 'homebranch set correctly' );
    is( $item->holdingbranch, $library->branchcode, 'holdingbranch set correctly' );
    is( $item->itype,         $itemtype->itemtype,  'itype set correctly' );
    is( $item->notforloan,    -1,                   'notforloan set to -1' );

    # skip_if_items_exist
    my $result2 = $plugin->_create_item_for_biblio({
        biblio              => $biblio,
        skip_if_items_exist => 1,
        default_homebranch    => $library->branchcode,
        default_holdingbranch => $library->branchcode,
        default_itype         => $itemtype->itemtype,
    });
    is( $result2, undef, 'Returns undef when items exist and skip_if_items_exist is set' );
};

subtest '_create_item_for_biblio resolves itype from MARC field' => sub {
    plan tests => 1;

    my $library = $builder->build_object({ class => 'Koha::Libraries' });

    my $record = MARC::Record->new;
    $record->append_fields(
        MARC::Field->new( '245', ' ', ' ', a => 'Test title' ),
        MARC::Field->new( '960', ' ', ' ', y => 'DVD' ),
    );

    my $biblio = C4::Biblio::AddBiblio( $record, '' );
    $biblio = Koha::Biblios->find($biblio);

    my $item = $plugin->_create_item_for_biblio({
        biblio                => $biblio,
        default_homebranch    => $library->branchcode,
        default_holdingbranch => $library->branchcode,
        default_itype         => '960$y',
    });

    is( $item->itype, 'DVD', 'Resolved itype from MARC 960$y' );
};

subtest 'cronjob_nightly calls create_items_for_today_vendor_imports with include_yesterday' => sub {
    plan tests => 2;

    my $called_with;
    my $module = Test::MockModule->new('Koha::Plugin::Com::ByWaterSolutions::CatalogingItemCreator');
    $module->mock( 'create_items_for_today_vendor_imports', sub {
        my ($self, $params) = @_;
        $called_with = $params;
        return 0;
    });

    $plugin->cronjob_nightly();

    ok( $called_with, 'cronjob_nightly calls create_items_for_today_vendor_imports' );
    is( $called_with->{include_yesterday}, 1, 'Passes include_yesterday => 1' );
};

$schema->storage->txn_rollback;
