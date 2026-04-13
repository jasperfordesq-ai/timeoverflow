module Api
  module V1
    class KomunitinController < BaseController
      # Komunitin endpoints use JSON:API format (application/vnd.api+json) per the
      # Komunitin protocol specification, not the standard REST envelope used by
      # the other API controllers. All responses and errors in this controller
      # follow the JSON:API structure: { data: [...] } for success and
      # { errors: [{ status: "4xx", title: "...", detail: "..." }] } for errors.
      #
      # These endpoints serve TO data in Komunitin JSON:API format.
      # They complement the existing REST endpoints — both coexist.

      before_action :require_organization!, except: [:currencies]
      before_action -> { require_permission!(:transactions) }, only: [:accounts, :account]
      before_action -> { require_permission!(:transactions) }, only: [:transfers, :transfer, :create_transfer]
      before_action :require_json_content_type!, only: [:create_transfer]

      # GET /api/v1/komunitin/currencies
      def currencies
        # Only show federation-enabled orgs, capped at 100 for safety.
        # Preload federation settings to avoid N+1 AccessControl.org_enabled? calls.
        fed_enabled_org_ids = FederationOrganizationSetting
          .where(federation_enabled: true).pluck(:organization_id)

        orgs = Organization.where(id: fed_enabled_org_ids).order(:name).limit(100)
        orgs = orgs.where(id: @current_api_key.organization_id) if @current_api_key&.organization_id

        data = orgs.map do |org|
          {
            type: "currencies",
            id: org.id.to_s,
            attributes: {
              code: "TO#{org.id}",
              name: org.name,
              namePlural: org.name,
              symbol: "h",
              decimals: 2,
              scale: 100,
              status: "active",
              rate: { n: 1, d: 1 },
              settings: {
                defaultAllowPayments: true,
                enableExternalPayments: fed_enabled_org_ids.include?(org.id)
              }
            }
          }
        end
        render json: { data: data }, status: :ok, content_type: "application/vnd.api+json"
      end

      # GET /api/v1/komunitin/:code/accounts
      def accounts
        members = current_organization.members.active.includes(:user, :account)

        # Apply consent filter
        discoverable_ids = Federation::AccessControl.discoverable_member_ids(current_organization)
        members = members.where(id: discoverable_ids)

        # Pagination
        page_size = [[(params.dig(:page, :size) || 25).to_i, 1].max, 100].min
        offset = [(params.dig(:page, :after) || 0).to_i, 0].max
        total = members.count
        members = members.offset(offset).limit(page_size)

        data = members.map { |m| serialize_account(m) }

        render json: {
          data: data,
          links: build_pagination_links(offset, page_size, total),
          meta: { total: total }
        }, status: :ok, content_type: "application/vnd.api+json"
      end

      # GET /api/v1/komunitin/:code/accounts/:id
      def account
        member = current_organization.members.active.find_by!(id: params[:id])
        discoverable_ids = Federation::AccessControl.discoverable_member_ids(current_organization)
        unless discoverable_ids.include?(member.id)
          raise ActiveRecord::RecordNotFound, "Account not found"
        end
        render json: { data: serialize_account(member) },
               status: :ok, content_type: "application/vnd.api+json"
      end

      # GET /api/v1/komunitin/:code/transfers
      def transfers
        txns = FederationTransaction.where(organization_id: current_organization.id)
          .order(created_at: :desc)

        page_size = [[(params.dig(:page, :size) || 25).to_i, 1].max, 100].min
        offset = [(params.dig(:page, :after) || 0).to_i, 0].max
        total = txns.count
        txns = txns.offset(offset).limit(page_size)

        data = txns.map { |t| serialize_transfer(t) }

        render json: {
          data: data,
          links: build_pagination_links(offset, page_size, total),
          meta: { total: total }
        }, status: :ok, content_type: "application/vnd.api+json"
      end

      # GET /api/v1/komunitin/:code/transfers/:id
      def transfer
        txn = FederationTransaction.find_by!(id: params[:id], organization_id: current_organization.id)
        render json: { data: serialize_transfer(txn) },
               status: :ok, content_type: "application/vnd.api+json"
      end

      # POST /api/v1/komunitin/:code/transfers
      def create_transfer
        # Parse JSON:API transfer document
        raw = request.raw_post
        if raw.blank?
          return render json: { errors: [{ status: "400", title: "Bad Request", detail: "Request body is required" }] },
                        status: :bad_request, content_type: "application/vnd.api+json"
        end
        begin
          body = JSON.parse(raw, max_nesting: 20)
        rescue JSON::ParserError => e
          return render json: { errors: [{ status: "400", title: "Bad Request", detail: "Invalid JSON" }] },
                        status: :bad_request, content_type: "application/vnd.api+json"
        end
        attrs = body.dig("data", "attributes") || {}
        rels = body.dig("data", "relationships") || {}

        # Convert Komunitin minor units to seconds
        scale = 100
        amount_seconds = ((attrs["amount"].to_f / scale) * 3600).round

        payer_id = rels.dig("payer", "data", "id")
        payee_id = rels.dig("payee", "data", "id")

        render json: { errors: [{ status: "501", title: "Not Implemented", detail: I18n.t("federation_api.errors.komunitin_transfers_not_implemented", default: "Transfer creation via Komunitin protocol is handled through the REST API") }] }, status: :not_implemented, content_type: "application/vnd.api+json"
      end

      private

      def serialize_account(member)
        balance_seconds = member.account&.balance.to_i
        balance_minor = (balance_seconds / 3600.0 * 100).round

        {
          type: "accounts",
          id: member.id.to_s,
          attributes: {
            code: "TO#{member.organization_id}#{member.id.to_s.rjust(4, '0')}",
            balance: balance_minor,
            creditLimit: 0
          },
          relationships: {
            currency: { data: { type: "currencies", id: member.organization_id.to_s } },
            users: { data: [{ type: "users", id: member.user_id.to_s, meta: { external: false } }] }
          }
        }
      end

      def serialize_transfer(txn)
        amount_minor = (txn.amount / 3600.0 * 100).round
        state = { "pending" => "new", "completed" => "committed", "cancelled" => "rejected" }[txn.status] || txn.status

        {
          type: "transfers",
          id: txn.id.to_s,
          attributes: {
            amount: amount_minor,
            meta: txn.reason.to_s,
            state: state,
            created: txn.created_at&.iso8601,
            updated: txn.updated_at&.iso8601
          },
          relationships: {
            payer: { data: { type: "accounts", id: (txn.outbound? ? txn.local_account_id : txn.remote_user_identifier).to_s } },
            payee: { data: { type: "accounts", id: (txn.inbound? ? txn.local_account_id : txn.remote_user_identifier).to_s } }
          }
        }
      end

      def build_pagination_links(offset, page_size, total)
        base = request.path
        links = {}
        links[:first] = "#{base}?page[after]=0&page[size]=#{page_size}"
        links[:last] = "#{base}?page[after]=#{[total - page_size, 0].max}&page[size]=#{page_size}"
        links[:prev] = "#{base}?page[after]=#{[offset - page_size, 0].max}&page[size]=#{page_size}" if offset > 0
        links[:next] = "#{base}?page[after]=#{offset + page_size}&page[size]=#{page_size}" if offset + page_size < total
        links
      end
    end
  end
end
