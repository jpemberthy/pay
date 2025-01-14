module Pay
  module Stripe
    class Charge
      attr_reader :pay_charge

      delegate :processor_id, :stripe_account, to: :pay_charge

      def self.sync(charge_id, object: nil, stripe_account: nil, try: 0, retries: 1)
        # Skip loading the latest charge details from the API if we already have it
        object ||= ::Stripe::Charge.retrieve(charge_id, {stripe_account: stripe_account}.compact)

        pay_customer = Pay::Customer.find_by(processor: :stripe, processor_id: object.customer)
        return unless pay_customer

        payment_method = object.payment_method_details.send(object.payment_method_details.type)
        attrs = {
          amount: object.amount,
          amount_refunded: object.amount_refunded,
          application_fee_amount: object.application_fee_amount,
          created_at: Time.at(object.created),
          currency: object.currency,
          stripe_account: pay_customer.stripe_account,
          metadata: object.metadata,
          payment_method_type: object.payment_method_details.type,
          brand: payment_method.try(:brand)&.capitalize,
          last4: payment_method.try(:last4).to_s,
          exp_month: payment_method.try(:exp_month).to_s,
          exp_year: payment_method.try(:exp_year).to_s,
          bank: payment_method.try(:bank_name) || payment_method.try(:bank) # eps, fpx, ideal, p24, acss_debit, etc
        }

        # Associate charge with subscription if we can
        if object.invoice
          invoice = (object.invoice.is_a?(::Stripe::Invoice) ? object.invoice : ::Stripe::Invoice.retrieve(object.invoice, {stripe_account: stripe_account}.compact))
          attrs[:subscription] = pay_customer.subscriptions.find_by(processor_id: invoice.subscription)
        end

        # Update or create the charge
        if (pay_charge = pay_customer.charges.find_by(processor_id: object.id))
          pay_charge.with_lock do
            pay_charge.update!(attrs)
          end
          pay_charge
        else
          pay_customer.charges.create!(attrs.merge(processor_id: object.id))
        end
      rescue ActiveRecord::RecordInvalid
        try += 1
        if try <= retries
          sleep 0.1
          retry
        else
          raise
        end
      end

      def initialize(pay_charge)
        @pay_charge = pay_charge
      end

      def charge
        ::Stripe::Charge.retrieve({id: processor_id, expand: ["customer", "invoice.subscription"]}, stripe_options)
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      # https://stripe.com/docs/api/refunds/create
      #
      # refund!
      # refund!(5_00)
      # refund!(5_00, refund_application_fee: true)
      def refund!(amount_to_refund, **options)
        ::Stripe::Refund.create(options.merge(charge: processor_id, amount: amount_to_refund), stripe_options)
        pay_charge.update(amount_refunded: amount_to_refund)
      rescue ::Stripe::StripeError => e
        raise Pay::Stripe::Error, e
      end

      private

      # Options for Stripe requests
      def stripe_options
        {stripe_account: stripe_account}.compact
      end
    end
  end
end
