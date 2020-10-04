# See: https://github.com/harpagon210/steemsmartcontracts/wiki/Nft-Contract#updateName
class NftUpdateUrl < ContractAction
  belongs_to :trx, class_name: 'Transaction', foreign_key: 'trx_id'
  
  validates_presence_of :trx
  validates_presence_of :symbol
  validates_presence_of :url
end
