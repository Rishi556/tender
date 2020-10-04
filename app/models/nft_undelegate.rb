# See: https://github.com/hive-engine/steemsmartcontracts-wiki/blob/master/NFT-Contracts.md#undelegate
class NftUndelegate < ContractAction
  belongs_to :trx, class_name: 'Transaction', foreign_key: 'trx_id'
  
  validates_presence_of :trx
  validates_presence_of :nfts
  
  def hydrated_nfts
    @nfts ||= JSON[nfts] rescue []
  end
end