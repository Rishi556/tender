require 'active_record/validations'

class Transaction < ApplicationRecord
  EXECUTED_CODE_HASH_EXCEPTIONS = [
    'contract doesn\'t exist'
  ]
  
  GENESIS_BLOCK = {
    block_num: 0,
    ref_steem_block_num: 0
  }
  
  with_options foreign_key: 'trx_id', dependent: :destroy do |trx|
    trx.has_many :contract_deploys
    trx.has_many :contract_updates
    trx.has_many :market_buys
    trx.has_many :market_cancels
    trx.has_many :market_sells
    trx.has_many :sscstore_buys
    trx.has_many :steempegged_buys
    trx.has_many :steempegged_remove_withdrawals
    trx.has_many :steempegged_withdraws
    trx.has_many :tokens_creates
    trx.has_many :tokens_enable_stakings
    trx.has_many :tokens_issues
    trx.has_many :tokens_stakes
    trx.has_many :tokens_transfer_ownerships
    trx.has_many :tokens_transfers
    trx.has_many :tokens_unstakes
    trx.has_many :tokens_update_metadata, class_name: 'TokensUpdateMetadata'
    trx.has_many :tokens_update_urls
    trx.has_many :tokens_update_params, class_name: 'TokensUpdateParams'
  end
  
  validates_presence_of :block_num
  validates_presence_of :ref_steem_block_num
  validates_presence_of :trx_id
  validates_presence_of :trx_in_block
  validates_presence_of :sender
  validates_presence_of :contract
  validates_presence_of :action
  validates_presence_of :payload
  validates_presence_of :executed_code_hash, unless: :executed_code_hash_exceptions
  validates_presence_of :hash
  validates_presence_of :database_hash, unless: :database_hash_exceptions
  validates_presence_of :logs
  validates_presence_of :timestamp
  
  validates_uniqueness_of :block_num, scope: %i(trx_id trx_in_block)
  validates_uniqueness_of :trx_in_block, scope: :trx_id
  validates_uniqueness_of :hash
  validates_uniqueness_of :database_hash, scope: %i(trx_id trx_in_block)
  
  after_commit :parse_contract, on: :create
  
  scope :contract, lambda { |contract, options = {}|
    if !!options[:invert]
      where.not(contract: contract)
    else
      where(contract: contract)
    end
  }
  
  scope :with_logs_errors, -> { where("logs LIKE '%\"errors\":%'") }
  
  scope :with_account, lambda { |account = nil|
    accounts = [account].flatten.map(&:downcase)
    where_clause = (['id IN(?)'] * 8).join(' OR ')
    
    where(where_clause,
      Transaction.where(sender: accounts).select(:id),
      Transaction.where('logs LIKE ?', "%\"#{accounts[0]}\"%").select(:id),
      TokensIssue.where(to: accounts).select(:trx_id),
      TokensTransfer.where(to: accounts).select(:trx_id),
      TokensTransferOwnership.where(to: accounts).select(:trx_id),
      SscstoreBuy.where(recipient: accounts).select(:trx_id),
      SteempeggedBuy.where(recipient: accounts).select(:trx_id),
      SteempeggedRemoveWithdrawal.where(recipient: accounts).select(:trx_id),
    )
  }
  
  scope :with_symbol, lambda { |symbol = nil|
    symbols = [symbol].flatten.compact.map(&:upcase)
    where_clause = (['id IN(?)'] * 12).join(' OR ')
    
    where(where_clause,
      Transaction.where(contract: 'market', action: 'buy').
        where('logs LIKE ?', "%\"#{symbols[0]}\"%").except(:order).select(:id),
      Transaction.where(contract: 'market', action: 'sell').
        where('logs LIKE ?', "%\"#{symbols[0]}\"%").except(:order).select(:id),
      TokensIssue.where(symbol: symbols).except(:order).select(:trx_id),
      TokensStake.where(symbol: symbols).except(:order).select(:trx_id),
      TokensTransfer.where(symbol: symbols).select(:trx_id),
      TokensCreate.where(symbol: symbols).select(:trx_id),
      TokensTransferOwnership.where(symbol: symbols).select(:trx_id),
      TokensUnstake.where(symbol: symbols).except(:order).select(:trx_id),
      TokensUpdateMetadata.where(symbol: symbols).select(:trx_id),
      TokensUpdateUrl.where(symbol: symbols).select(:trx_id),
      MarketBuy.where(symbol: symbols).select(:trx_id),
      MarketSell.where(symbol: symbols).select(:trx_id),
    )
  }
  
  scope :search, lambda { |options = {}|
    keywords = [options[:keywords]].flatten.compact.map(&:downcase)
    keywords = keywords.map { |keyword| "%#{keyword}%"}
    
    where_clause = keywords.map do |keyword|
      <<~DONE
        block_num LIKE ? OR
        ref_steem_block_num LIKE ? OR
        trx_id LIKE ? OR
        sender LIKE ? OR
        contract LIKE ? OR
        action LIKE ? OR
        LOWER(payload) LIKE ? OR
        LOWER(logs) LIKE ? OR
        executed_code_hash LIKE ? OR
        hash LIKE ? OR
        database_hash LIKE ? OR
        timestamp LIKE ?
      DONE
    end
    
    where(where_clause.join(' OR '), *keywords * 12)
  }
  
  def self.meeseeker_ingest(&block)
    pattern = 'steem_engine:*:*:*:*'
    ctx = Redis.new(url: ENV.fetch('MEESEEKER_REDIS_URL', 'redis://127.0.0.1:6379/0'))
    
    ctx.scan_each(match: pattern) do |key|
      n, b, t, i = key.split(':')
      params = JSON[ctx.get(key)]
      trx_id = params['transactionId'].to_s.split('-')[0]
      b = b.to_i
      i = i.to_i
      
      if Transaction.where(block_num: b, trx_id: trx_id, trx_in_block: i).any?
        Rails.logger.warn("Already ingested: #{key} (skipped)")
        ctx.del(key)
        next
      end
      
      transaction = Transaction.create(
        block_num: b,
        trx_id: trx_id,
        trx_in_block: i,
        ref_steem_block_num: params['refSteemBlockNumber'],
        sender: params['sender'],
        contract: params['contract'],
        action: params['action'],
        payload: params['payload'],
        executed_code_hash: params['executedCodeHash'],
        logs: params['logs'],
        timestamp: Time.parse(params['timestamp'] + 'Z'),
        hash: params['hash'],
        database_hash: params['databaseHash'],
      )
      
      if transaction.errors.any?
        # raise "Unable to save #{key}: #{transaction.errors.messages}"
        Rails.logger.warn "Unable to save #{key}: #{transaction.errors.messages}"
        ctx.del(key)
        next
      end
      
      yield transaction, key if !!block
      
      if transaction.persisted?
        ctx.del(key)
      else
        Rails.logger.warn("Did not persist: #{key}")
      end
    end
  end
  
  def hydrated_payload
    @hydrated_payload ||= JSON[payload] rescue {}
  end
  
  def hydrated_logs
    @hydrated_logs ||= JSON[logs] rescue {}
  end
private
  def executed_code_hash_exceptions
    (hydrated_logs['errors'] || [] & EXECUTED_CODE_HASH_EXCEPTIONS).any?
  end
  
  def database_hash_exceptions
    block_num == GENESIS_BLOCK[:block_num]
  end
  
  def parse_contract
    if (hydrated_logs['errors'] || []).any?
      Rails.logger.debug("Ignoring action (trx_id: #{trx_id}): #{contract}.#{action}; errors: #{hydrated_logs['errors'].to_json}")
      
      return
    end
    
    class_name = "#{contract.upcase_first}#{action.upcase_first}"
    klass = begin
      Object.const_get(class_name)
    rescue NameError
      Rails.logger.debug("Unsupported action (trx_id: #{trx_id}): #{contract}.#{action} (no class defined for: #{class_name})")
      
      nil
    end
    
    if !!klass
      params = hydrated_payload
      params.delete('isSignedWithActiveKey')
      params['action_type'] = params.delete('type') if !!params['type']
      params['action_id'] = params.delete('id') if !!params['id']
      params.deep_transform_keys!(&:underscore)
      params.select!{ |k, _v| klass.attribute_names.index(k) }
      
      params = params.map do |k, v|
        case v
        when Hash, Array then [k, v.to_json]
        else; [k, v]
        end
      end.to_h
      
      begin
        klass.create!(params.merge(trx: self))
      rescue => e
        raise "Unable to create record (trx_id: #{trx_id}): #{contract}.#{action} (params: #{params}) (caused by: #{e})"
      end
    end
  end
end
