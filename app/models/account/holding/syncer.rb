class Account::Holding::Syncer
  def initialize(account, start_date: nil)
    @account = account
    @sync_date_range = calculate_sync_start_date(start_date)..Date.current
    @portfolio = {}

    load_prior_portfolio if start_date
  end

  def run
    holdings = []

    sync_date_range.each do |date|
      holdings += build_holdings_for_date(date)
    end

    upsert_holdings holdings
  end

  private

    attr_reader :account, :sync_date_range

    def sync_entries
      @sync_entries ||= account.entries
                               .account_trades
                               .includes(entryable: :security)
                               .where("date >= ?", sync_date_range.begin)
                               .order(:date)
    end

    def get_cached_price(ticker, date)
      return nil unless security_prices.key?(ticker)

      price = security_prices[ticker].find { |p| p.date == date }
      price ? price[:price] : nil
    end

    def security_prices
      @security_prices ||= begin
        prices = {}
        ticker_securities = {}

        sync_entries.each do |entry|
          security = entry.account_trade.security
          unless ticker_securities[security.ticker]
            ticker_securities[security.ticker] = {
              security: security,
              start_date: entry.date
            }
          end
        end

        ticker_securities.each do |ticker, data|
          fetched_prices = Security::Price.find_prices(
            security: data[:security],
            start_date: data[:start_date],
            end_date: Date.current
          )
          gapfilled_prices = Gapfiller.new(fetched_prices, start_date: data[:start_date], end_date: Date.current, cache: false).run
          prices[ticker] = gapfilled_prices
        end

        prices
      end
    end

    def build_holdings_for_date(date)
      trades = sync_entries.select { |trade| trade.date == date }

      @portfolio = generate_next_portfolio(@portfolio, trades)

      @portfolio.map do |ticker, holding|
        trade = trades.find { |trade| trade.account_trade.security_id == holding[:security_id] }
        trade_price = trade&.account_trade&.price

        price = get_cached_price(ticker, date) || trade_price

        account.holdings.build \
          date: date,
          security_id: holding[:security_id],
          qty: holding[:qty],
          price: price,
          amount: price ? (price * holding[:qty]) : nil,
          currency: holding[:currency]
      end
    end

    def generate_next_portfolio(prior_portfolio, trade_entries)
      trade_entries.each_with_object(prior_portfolio) do |entry, new_portfolio|
        trade = entry.account_trade

        price = trade.price
        prior_qty = prior_portfolio.dig(trade.security.ticker, :qty) || 0
        new_qty = prior_qty + trade.qty

        new_portfolio[trade.security.ticker] = {
          qty: new_qty,
          price: price,
          amount: new_qty * price,
          currency: entry.currency,
          security_id: trade.security_id
        }
      end
    end

    def upsert_holdings(holdings)
      current_time = Time.now
      holdings_to_upsert = holdings.map do |holding|
        holding.attributes
               .slice("date", "currency", "qty", "price", "amount", "security_id")
               .merge("updated_at" => current_time)
      end

      account.holdings.upsert_all(holdings_to_upsert, unique_by: %i[account_id security_id date currency])
    end

    def load_prior_portfolio
      prior_day_holdings = account.holdings.where(date: sync_date_range.begin - 1.day)

      prior_day_holdings.each do |holding|
        @portfolio[holding.security.ticker] = {
          qty: holding.qty,
          price: holding.price,
          amount: holding.amount,
          currency: holding.currency,
          security_id: holding.security_id
        }
      end
    end

    def calculate_sync_start_date(start_date)
      start_date || account.entries.account_trades.order(:date).first.try(:date) || Date.current
    end
end
