package Koha::Plugin::Com::PTFSEurope::WPMPayments;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Auth;
use Koha::Account;
use Koha::Account::Lines;
use Cwd qw(abs_path);
use Mojo::UserAgent;

use XML::LibXML;
use Digest::MD5 qw(md5_hex);

## Here we set our plugin version
our $VERSION = "00.00.01";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'WPM Online Payments Plugin',
    author          => 'Martin Renvoize',
    date_authored   => '2018-06-13',
    date_updated    => "2018-06-13",
    minimum_version => '17.11.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin implements online payments using '
      . 'WPM Educations payments platform.',
};

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    return $self->retrieve_data('enable_opac_payments') eq 'Yes';
}

## Initiate the payment process
sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    my $cgi    = $self->{'cgi'};
    my $schema = Koha::Database->new()->schema();

    my ( $template, $borrowernumber ) = get_template_and_user(
        {
            template_name =>
              abs_path( $self->mbf_path('opac_online_payment_error.tt') ),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    # Get the borrower
    my $borrower_result = Koha::Patrons->find($borrowernumber);

    # Construct redirect URI
    my $redirect_url = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account-pay-return.pl" );
    $redirect_url->query_form(
        { payment_method => scalar $cgi->param('payment_method') } );

    # Construct callback URI
    my $callback_url =
      URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac/opac-account-pay-return.pl" );
    $callback_url->query(
        { payment_method => scalar $cgi->param('payment_method') } );

    # Construct cancel URI
    my $cancel_url = URI->new( C4::Context->preference('OPACBaseURL')
          . "/cgi-bin/koha/opac-account-pay-return.pl" );
    $cancel_url->query(
        { payment_method => scalar $cgi->param('payment_method'), cancel => 1 }
    );

    # Create a transaction
    my $transaction_result =
      $schema->resultset('AcTransaction')
      ->create( { updated => DateTime->now } );
    my $transaction_id = $transaction_result->transaction_id;

    # Construct XML POST
    my $xml = XML::LibXML::Document->new( '1.0', 'utf-8' );
    my $root = $xml->createElement('wpmpaymentrequest');

    my @fields = (
        {
            name => 'clientid',
            value =>
              { value => $self->retrieve_data('WPMClientID'), cdata => 0 }
        },
        {
            name  => 'requesttype',
            value => { value => 1, cdata => 0 }
        },
        {
            name => 'pathwayid',
            value =>
              { value => $self->retrieve_data('WPMPathwayID'), cdata => 0 }
        },
        {
            name  => 'departmentid',
            value => {
                value => $self->retrieve_data('WPMDepartmentID'),
                cdata => 0
            }
        },
        { name => 'staffid', value => { value => undef, cdata => 0 } },
        {
            name  => 'customerid',
            value => { value => $borrowernumber, cdata => 0 }
        },    #studentnumber
        {
            name  => 'title',
            value => { value => $borrower_result->title, cdata => 1 }
        },
        {
            name  => 'firstname',
            value => { value => $borrower_result->firstname, cdata => 1 }
        },
        {
            name  => 'middlename',
            value => { value => $borrower_result->othernames, cdata => 1 }
        },
        {
            name  => 'lastname',
            value => { value => $borrower_result->surname, cdata => 1 }
        },
        {
            name  => 'emailfrom',
            value => {
                value => C4::Context->preference('KohaAdminEmailAddress'),
                cdata => 1
            }
        },
        {
            name  => 'toemail',
            value => { value => $borrower_result->email, cdata => 1 }
        },
        { name => 'ccemail', value => { value => undef, cdata => 1 } },
        {
            name  => 'transactionreference',
            value => { value => $transaction_id, cdata => 1 }
        },
        {
            name  => 'redirecturl',
            value => { value => $redirect_url, cdata => 1 }
        },
        {
            name  => 'callbackurl',
            value => { value => $callback_url, cdata => 1 }
        },
        {
            name  => 'cancelurl',
            value => { value => $cancel_url, cdata => 1 }
        },
        {
            name  => 'billaddress1',
            value => { value => $borrower_result->streetnumber, cdata => 1 }
        },
        {
            name  => 'billaddress2',
            value => { value => $borrower_result->address, cdata => 1 }
        },
        {
            name  => 'billaddress3',
            value => { value => $borrower_result->address2, cdata => 1 }
        },
        {
            name  => 'billtown',
            value => { value => $borrower_result->city, cdata => 1 }
        },
        {
            name  => 'billcounty',
            value => { value => $borrower_result->state, cdata => 1 }
        },
        {
            name  => 'billpostcode',
            value => { value => $borrower_result->zipcode, cdata => 1 }
        },
        {
            name  => 'billcountry',
            value => { value => $borrower_result->country, cdata => 1 }
        },
        { name => 'customfield1', value => undef },
        { name => 'customfield2', value => undef },
        { name => 'customfield3', value => undef },
        { name => 'customfield4', value => undef },
        { name => 'customfield5', value => undef },
        { name => 'customfield6', value => undef },
        { name => 'customfield7', value => undef },
        { name => 'customfield8', value => undef },
        { name => 'customfield9', value => undef },
        {
            name  => 'customfield10',
            value => undef
        }
    );

    for my $field (@fields) {
        my $tag   = $xml->createElement( $field->{name} );
        my $value = $field->{value};
        if ( defined( $value->{'value'} ) && $value->{'value'} ne '' ) {
            if ( $value->{'cdata'} ) {
                my $data = XML::LibXML::CDATASection->new("$value->{'value'}");
                $tag->appendChild($data);
            }
            else {
                $tag->appendTextNode( $value->{'value'} );
            }
        }
        $root->appendChild($tag);
    }

    # Add the accountlines to pay off
    my @accountline_ids = $cgi->multi_param('accountline');
    my $accountlines    = $schema->resultset('Accountline')
      ->search( { accountlines_id => \@accountline_ids } );
    my $now               = DateTime->now;
    my $dateoftransaction = $now->ymd('-') . ' ' . $now->hms(':');
    my $pay_count         = 0;
    my $sum               = 0;
    for my $accountline ( $accountlines->all ) {

        # Track sum
        my $amount = sprintf "%.2f", $accountline->amountoutstanding;
        $sum = $sum + $amount;

        # Build payments block
        #####################
        my $payments = $xml->createElement('payments');
        $payments->setAttribute( 'id'        => ++$pay_count );
        $payments->setAttribute( 'type'      => 'PN' );
        $payments->setAttribute( 'payoption' => $accountline->accounttype );

        my $description = $xml->createElement("description");
        if ( defined( $accountline->description )
            && $accountline->description ne '' )
        {
            my $data =
              XML::LibXML::CDATASection->new( $accountline->description );
            $description->appendChild($data);
        }
        $payments->appendChild($description);

        my $payment = $xml->createElement("payment");
        $payment->setAttribute( 'payid' => "$pay_count" );

        my $customfield1 = $xml->createElement("customfield1");
        $payment->appendChild($customfield1);

        my $amounttopay = $xml->createElement("amounttopay");
        $amounttopay->appendTextNode($amount);
        $payment->appendChild($amounttopay);

        my $amounttopayvat = $xml->createElement("amounttopayvat");
        $amounttopayvat->appendTextNode('0');
        $payment->appendChild($amounttopayvat);

        my $amounttopayexvat = $xml->createElement("amounttopayexvat");
        $amounttopayexvat->appendTextNode($amount);
        $payment->appendChild($amounttopayexvat);

        my $vatdesc = $xml->createElement("vatdesc");
        $vatdesc->appendTextNode('Exempt');
        $payment->appendChild($vatdesc);

        my $vatcode = $xml->createElement("vatcode");
        $vatcode->appendTextNode('E');
        $payment->appendChild($vatcode);

        my $vatrate = $xml->createElement("vatrate");
        $vatrate->appendTextNode('0');
        $payment->appendChild($vatrate);

        my $dateofpayment = $xml->createElement("dateofpayment");
        $dateofpayment->appendTextNode($dateoftransaction);
        $payment->appendChild($dateofpayment);

        my $editable = $xml->createElement("editable");
        $editable->setAttribute( 'minamount' => "0" );
        $editable->setAttribute( 'maxamount' => "0" );
        $editable->appendTextNode(0);
        $payment->appendChild($editable);

        my $mandatory = $xml->createElement("mandatory");
        $mandatory->appendTextNode(1);
        $payment->appendChild($mandatory);

        # Add 'payment' to 'payments' block
        $payments->appendChild($payment);

        # Add 'payments' to 'root' block
        $root->appendChild($payments);

        #
        # Link accountline to the transaction
        # [Set status '1' to reperesent request sent]
        my $transactionAccount_result =
          $schema->resultset('AcTransactionAccount')->create(
            {
                accountline_id => $accountline->accountlines_id,
                transaction_id => $transaction_id,
                status         => 1
            }
          );
    }

    # Add signature to xml
    $sum = sprintf "%.2f", $sum;
    my $msgid =
      md5_hex( $self->retrieve_data('WPMClientID')
          . $transaction_id
          . $sum
          . $self->retrieve_data('WPMSecret') );
    $root->setAttribute( 'msgid' => "$msgid" );

    # Finalise XML Document
    $xml->setDocumentElement($root);

    # Send POST to WPM
    my $ua = Mojo::UserAgent->new( max_redirects => 0 );
    my $pathway = $self->retrieve_data('WPMPathway');
    my $tx =
      $ua->post(
        $pathway => form => { xml => $xml->toString() } => charset => 'UTF-8' );
    if ( my $res = $tx->success ) {
        print $cgi->redirect( $res->headers->header("location") );
    }
    else {
        my $err = $tx->error;
        $template->param();

        $self->output_html( $template->output() );

        die "$err->{code} response: $err->{message}" if $err->{code};
        die "Connection error: $err->{message}";
    }

}

## Complete the payment process
sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    if ( my $post = $cgi->param('POSTDATA') ) {
        my $xml;
        eval { $xml = XML::LibXML->load_xml( string => $post ) };
        warn "error: " . $@ if $@;

        my @rootNode = $xml->findnodes('/wpmpaymentrequest');
        my $transaction =
          $xml->findnodes('/wpmpaymentrequest/transactionreference');
        my $success = $xml->findnodes('/wpmpaymentrequest/transaction/success');

        if ( $success eq '1' ) {
            my $schema = Koha::Database->new()->schema();

            # Make payments (associating them to a transaction)
            my @accountlines = $schema->resultset('AcTransactionAccount')
              ->search( { transaction_id => $transaction } )->all;

            # FIXME: These should really be grouped into one
            # 'Pay' line in accountlines
            for my $account (@accountlines) {
                my $dump = { $account->get_columns };

                # Make Payment
                my $paymentID = makepayment(
                    $account->accountline_id,
                    $account->accountline->borrowernumber->borrowernumber,
                    $account->accountline->accountno,
                    $account->accountline->amount
                );

                # Update Transaction (2 = success)
                $account->update( { status => '2' } );

                # Add payment accountline to transaction group
                my $transactionAccount_result =
                  $schema->resultset('AcTransactionAccount')->create(
                    {
                        accountline_id => $paymentID,
                        transaction_id => $transaction,
                        status         => 2
                    }
                  );

                # Renew if required
                if ( defined( $account->accountline->accounttype )
                    && $account->accountline->accounttype eq "FU" )
                {
                    if (
                        CheckIfIssuedToPatron(
                            $account->accountline->borrowernumber
                              ->borrowernumber,
                            $account->accountline->itemnumber->biblionumber
                        )
                      )
                    {
                        my $datedue = AddRenewal(
                            $account->accountline->borrowernumber
                              ->borrowernumber,
                            $account->accountline->itemnumber->itemnumber
                        );
                        C4::Circulation::_FixOverduesOnReturn(
                            $account->accountline->borrowernumber
                              ->borrowernumber,
                            $account->accountline->itemnumber->itemnumber
                        );
                    }
                }
            }

            # Respond with OK
            my $response = new CGI;
            my $reply    = XML::LibXML::Document->new( '1.0', 'utf-8' );
            my $root     = $reply->createElement("wpmmessagevalidation");
            my $md5      = $rootNode[0]->getAttribute('msgid');
            $root->setAttribute( 'msgid' => "$md5" );

            my $validation = $reply->createElement('validation');
            $validation->appendTextNode("1");
            $root->appendChild($validation);

            my $validationmessage = $reply->createElement('validationmessage');
            my $success           = XML::LibXML::CDATASection->new("Success");
            $validationmessage->appendChild($success);
            $root->appendChild($validationmessage);

            $reply->setDocumentElement($root);

            print CGI->header('text/xml');
            print $reply->toString();
        }
        else {
            # Update transaction status
            #
            # Respond OK

            my $reply = XML::LibXML::Document->new( '1.0', 'utf-8' );
            my $root  = $reply->createElement("wpmmessagevalidation");
            my $md5   = $rootNode[0]->getAttribute('msgid');
            $root->setAttribute( 'msgid' => "$md5" );

            my $validation = $reply->createElement('validation');
            $validation->appendTextNode("1");
            $root->appendChild($validation);

            my $validationmessage = $reply->createElement('validationmessage');
            my $success           = XML::LibXML::CDATASection->new("Success");
            $validationmessage->appendChild($success);
            $root->appendChild($validationmessage);

            $reply->setDocumentElement($root);

            print CGI->header('text/xml');
            print $reply->toString();
        }

    }
    else {

        my ( $template, $borrowernumber ) = get_template_and_user(
            {
                template_name =>
                  abs_path( $self->mbf_path('opac_online_payment_end.tt') ),
                query           => $cgi,
                type            => 'opac',
                authnotrequired => 0,
                is_plugin       => 1,
            }
        );
    }
}

## If your plugin needs to add some CSS to the OPAC, you'll want
## to return that CSS here. Don't forget to wrap your CSS in <style>
## tags. By not adding them automatically for you, you'll have a chance
## to include external CSS files as well!
sub opac_head {
    my ($self) = @_;

    return q|
        <style>
          body {
            background-color: orange;
          }
        </style>
    |;
}

## If your tool is complicated enough to needs it's own setting/configuration
## you will want to add a 'configure' method to your plugin like so.
## Here I am throwing all the logic into the 'configure' method, but it could
## be split up like the 'report' method is.
sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_opac_payments =>
              $self->retrieve_data('enable_opac_payments'),
            WPMClientID     => $self->retrieve_data('WPMClientID'),
            WPMSecret       => $self->retrieve_data('WPMSecret'),
            WPMPathway      => $self->retrieve_data('WPMPathway'),
            WPMPathwayID    => $self->retrieve_data('WPMPathwayID'),
            WPMDepartmentID => $self->retrieve_data('WPMDepartmentID'),
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                enable_opac_payments => $cgi->param('enable_opac_payments'),
                WPMClientID          => $cgi->param('WPMClientID'),
                WPMPathway           => $cgi->param('WPMPathway'),
                WPMPathwayID         => $cgi->param('WPMPathwayID'),
                WPMDepartmentID      => $cgi->param('WPMDepartmentID'),
                WPMSecret            => $cgi->param('WPMSecret'),
                last_configured_by   => C4::Context->userenv->{'number'},
            }
        );
        $self->go_home();
    }
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
#sub install() {
#    my ( $self, $args ) = @_;
#
#    my $table = $self->get_qualified_table_name('mytable');
#
#    return C4::Context->dbh->do( "
#        CREATE TABLE  $table (
#            `borrowernumber` INT( 11 ) NOT NULL
#        ) ENGINE = INNODB;
#    " );
#}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
#sub upgrade {
#    my ( $self, $args ) = @_;
#
#    my $dt = dt_from_string();
#    $self->store_data(
#        { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );
#
#    return 1;
#}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
#sub uninstall() {
#    my ( $self, $args ) = @_;
#
#    my $table = $self->get_qualified_table_name('mytable');
#
#    return C4::Context->dbh->do("DROP TABLE $table");
#}

1;
