{WalletDb} = require './wallet_db'
{TransactionLedger} = require '../wallet/transaction_ledger'
{ChainInterface} = require '../blockchain/chain_interface'
{ChainDatabase} = require '../blockchain/chain_database'
{BlockchainAPI} = require '../blockchain/blockchain_api'
{ExtendedAddress} = require '../ecc/extended_address'
{PrivateKey} = require '../ecc/key_private'
{PublicKey} = require '../ecc/key_public'
{Aes} = require '../ecc/aes'

#{Transaction} = require '../blockchain/transaction'
#{RegisterAccount} = require '../blockchain/register_account'
#{Withdraw} = require '../blockchain/withdraw'

LE = require('../common/exceptions').LocalizedException
EC = require('../common/exceptions').ErrorWithCause
config = require './config'
hash = require '../ecc/hash'
secureRandom = require 'secure-random'
q = require 'q'

###* Public ###
class Wallet

    constructor: (@wallet_db, @rpc) ->
        throw new Error "required parameter" unless @wallet_db
        @transaction_ledger = new TransactionLedger()
        @blockchain_api = new BlockchainAPI @rpc
        @chain_interface = new ChainInterface @blockchain_api
        @chain_database = new ChainDatabase @wallet_db, @rpc
    
    
    Wallet.entropy = null
    Wallet.add_entropy = (data) ->
        unless data and data.length >= 1000
            throw 'Provide at least 1000 bytes of data'
        
        data = new Buffer(data)
        data = Buffer.concat [Wallet.entropy, data] if Wallet.entropy
        Wallet.entropy = hash.sha512 data
        return
        
    Wallet.has_secure_random = ->
        try
            secureRandom.randomBuffer 10
            true
        catch
            false
    
    Wallet.get_secure_random = ->
        throw 'Call add_entropy first' unless Wallet.entropy
        rnd = secureRandom.randomBuffer 512/8
        #console.log 'Wallet.get_secure_random length',(Buffer.concat [rnd, Wallet.entropy]).length
        hash.sha512 Buffer.concat [rnd, Wallet.entropy]
    
    ###* Unless brain_key is used, must add_entropy first ### 
    Wallet.create = (wallet_name, password, brain_key, save = true)->
        wallet_name = wallet_name?.trim()
        unless wallet_name and wallet_name.length > 0
            LE.throw "wallet.invalid_name"
        
        if not password or password.length < config.BTS_WALLET_MIN_PASSWORD_LENGTH
            LE.throw "wallet.password_too_short"
        
        if brain_key and brain_key.length < config.BTS_WALLET_MIN_BRAINKEY_LENGTH
            LE.throw "wallet.brain_key_too_short"
        
        #@blockchain.is_valid_account_name wallet_name
        
        data = if brain_key
            throw 'Brain keys have not been tested with the native client'
            base = hash.sha512 brain_key
            for i in [0..100*1000]
                # strengthen the key a bit
                base = hash.sha512 base
            base
        else
            # generate random
            Wallet.get_secure_random()
        
        epk = ExtendedAddress.fromSha512 data
        wallet_db = WalletDb.create wallet_name, epk, password, save
        ###
        set_version( BTS_WALLET_VERSION );
        set_transaction_fee( asset( BTS_WALLET_DEFAULT_TRANSACTION_FEE ) );
        set_transaction_expiration( BTS_WALLET_DEFAULT_TRANSACTION_EXPIRATION_SEC );
        wallet_db.save() if save
        ###
        wallet_db
    
    lock: ->
        EC.throw "Wallet is already locked" unless @aes_root
        @aes_root.clear()
        @aes_root = undefined
        
    locked: ->
        @aes_root is undefined
            
    toJson: (indent_spaces=undefined) ->
        JSON.stringify(@wallet_db.wallet_object, undefined, indent_spaces)
    
    unlock: (timeout_seconds = 1700, password)->
        @wallet_db.validate_password password
        @aes_root = Aes.fromSecret password
        unlock_timeout_id = setTimeout ()=>
            @lock()
        ,
            timeout_seconds * 1000
        unlock_timeout_id
    
    validate_password: (password)->
        @wallet_db.validate_password password
    
    master_private_key:->
        LE.throw 'wallet.must_be_unlocked' unless @aes_root
        @wallet_db.master_private_key @aes_root
    
    get_setting: (key) ->
        @wallet_db.get_setting key 
        
    set_setting: (key, value) ->
        @wallet_db.set_setting key, value
        
    get_transaction_fee:()->#desired_asset_id = 0
        #defer = q.defer()
        default_fee = @wallet_db.get_transaction_fee()
        return default_fee #if desired_asset_id is 0
        #@blockchain_api.get_asset(desired_asset_id).then(
        #    (asset)=>
        #        if asset.is_market_issued
        #            #get_active_feed_price is not implemented (alt is to use blockchain_list_assets then blockchain_market_status {current_feed_price}
        #            @blockchain_api.get_active_feed_price(desired_asset_id).then(
        #                (median_price)->
        #                    fee = default_fee.amount
        #                    fee += fee + fee
        #                    # fee paid in something other than XTS is discounted 50%
        #                    alt_fee = fee * median_price
        #                    defer.resolve alt_fee
        #                    return
        #            ).done()
        #        else
        #            defer.resolve null
        #    (error)->
        #            defer.reject error
        #)
        #defer.promise
    
    get_trx_expiration:->
        @wallet_db.get_trx_expiration()
    
    list_accounts:(just_mine=false)->
        accounts = @wallet_db.list_accounts just_mine
        accounts.sort (a, b)->
            if a.name < b.name then -1
            else if a.name > b.name then 1
            else 0
        accounts
    
    get_local_account:(name)->
        @wallet_db.lookup_account name
    
    is_my_account:(public_key)->
        @wallet_db.is_my_account public_key
    
    ###*
        Get an account, try to sync with blockchain account 
        cache in wallet_db.
    ###
    get_chain_account:(name)-> # was lookup_account
        defer = q.defer()
        @blockchain_api.get_account(name).then (chain_account)=>
            local_account = @wallet_db.lookup_account name
            unless local_account or chain_account
                error = new LE "general.unknown_account", [name]
                defer.reject error
                return
            
            if local_account and chain_account
                if local_account.owner_key isnt chain_account.owner_key
                    error = new LE "wallet.conflicting_accounts", [name]
                    defer.reject error
                    return
            
            if chain_account
                @wallet_db.store_account_or_update chain_account
                local_account = @wallet_db.lookup_account name
            
            defer.resolve local_account
            return
        , (error)->defer.reject error
        defer.promise
    
    ###* @return promise: {string} public key ###
    account_create:(account_name, private_data)->
        LE.throw 'wallet.must_be_unlocked' unless @aes_root
        defer = q.defer()
        @chain_interface.valid_unique_account(account_name).then(
            ()=>
                #cnt = @wallet_db.list_my_accounts()
                account = @wallet_db.lookup_account account_name
                if account
                    e = new LE 'wallet.account_already_exists',[account_name]
                    defer.reject e
                    return
                
                key = @wallet_db.generate_new_account @aes_root, account_name, private_data
                defer.resolve key
            (error)->
                defer.reject error
        ).done()
        defer.promise
    
    ### @return {promise} [
        [
            account_name,[ [asset_id,amount] ]
        ]
    ] ###
    #get_spendable_account_balances:(account_name)->
        
    
    getWithdrawConditions:(account_name)->
        @wallet_db.getWithdrawConditions account_name
    
    getNewPrivateKey:(account_name, save = true)->
        LE.throw 'wallet.must_be_unlocked' unless @aes_root
        @wallet_db.generate_new_account_child_key @aes_root, account_name, save
    ###
    wallet_transfer:(
        amount, asset, 
        paying_name, from_name, to_name
        memo_message = "", vote_method = ""
    )->
        LE.throw 'wallet.must_be_unlocked' unless @aes_root
        defer = q.defer()
        to_public = @wallet_db.getActiveKey to_name
        #console.log to_name,to_public?.toBtsPublic()
        @rpc.request("blockchain_get_account",[to_name]).then(
            (result)=>
                unless result or to_public
                    error = new LE 'blockchain.unknown_account', [to_name]
                    defer.reject error
                    return
                
                recipient = @wallet_db.get_account to_name if result
                    @wallet_db.index_account result # cache
                    to_public = @wallet_db.getActiveKey to_name
                
                builder = @transaction_builder()
                
            (error)->
                defer.reject error
        ).done()
        defer.promise
    

    ###
    
    save_transaction:(record)->
        @wallet_db.add_transaction_record record
        return
    
    
    account_transaction_history:(
        account_name=""
        asset_id=0
        limit=0
        start_block_num=0
        end_block_num=-1
        transactions
    )->
        @chain_database.account_transaction_history(
            account_name
            asset_id
            limit
            start_block_num
            end_block_num
        )
    
    valid_unique_account:(account_name) ->
        @chain_interface.valid_unique_account account_name
    
    #asset_can_pay_fee:(asset_id)->
    #    fee = @get_transaction_fee()
    #    fee.asset_id is asset_id
    
    dump_private_key:(account_name)->
        LE.throw 'wallet.must_be_unlocked' unless @aes_root
        account = @wallet_db.lookup_account account_name
        return null unless account
        rec = @wallet_db.get_key_record account.owner_key
        return null unless rec
        @aes_root.decryptHex rec.encrypted_private_key
    
    get_new_private_key:(account_name, save) ->
        @generate_new_account_child_key @aes_root, account_name, save
        
    get_new_public_key:(account_name) ->
        @get_new_private_key(account_name).toPublicKey()
    
    get_my_key_records:(owner_key) ->
        @wallet_db.get_my_key_records owner_key
    
    getOwnerKey: (account_name)->
        account = @wallet_db.lookup_account account_name
        return null unless account
        PublicKey.fromBtsPublic account.owner_key
    
    getOwnerPrivate: (aes_root, account_name)->
        LE.throw 'wallet.must_be_unlocked' unless @aes_root
        account = @wallet_db.lookup_account account_name
        return null unless account
        account.owner_key
        @getPrivateKey account.owner_key
    
    lookup_active_key:(account_name)->
        @wallet_db.lookup_active_key account_name
    
    get_account_for_address:(address)->
        @wallet_db.get_account_for_address address
    
    keyrec_to_private:(key_record)->
        LE.throw 'wallet.must_be_unlocked' unless @aes_root
        return null unless key_record?.encrypted_private_key
        PrivateKey.fromHex @aes_root.decryptHex key_record.encrypted_private_key
        
    #lookup_private:(bts_public_key)->@getPrivateKey bts_public_key
    getPrivateKey:(bts_public_key)->
        @keyrec_to_private @wallet_db.get_key_record bts_public_key
    
    hasPrivate:(address)->
        key_record = @wallet_db.lookup_key address
        if key_record?.encrypted_private_key then yes else no
        
    lookupPrivateKey:(address)->
        @keyrec_to_private @wallet_db.lookup_key address
    
    #getNewPublicKey:(account_name)->
    
    ###* @return {PublicKey} ###
    getActiveKey: (account_name) ->
        active_key = @wallet_db.lookup_active_key account_name
        return null unless active_key
        PublicKey.fromBtsPublic active_key
        
    ###* @return {PrivateKey} ###
    getActivePrivate: (account_name) ->
        LE.throw 'wallet.must_be_unlocked' unless @aes_root
        @wallet_db.getActivePrivate @aes_root, account_name
    
exports.Wallet = Wallet