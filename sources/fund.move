module simple_fund::fund{
    use sui::object::{Self, UID, ID};
    use sui::balance::{Self, Balance};
    use std::string::{String};
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};
    use std::vector;
    use sui::bag::{Self, Bag};
    use sui::transfer;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};

    use cetus_clmm::pool::{Self, Pool};
    use cetus_clmm::config::GlobalConfig;
    use simple_fund::invest;

    //Error Code
    const EBalanceNotEnough: u64 = 0;
    const EObjectCoinNotEnough: u64 = 1;
    const EOverMaxAmount: u64 = 2;
    const EDifferentPuddle:u64 = 3;
    
    struct Fund<phantom T> has key, store{
        id: UID,
        balance: Balance<T>,
        commission_percentage: u8,
        investments: InvestmentsRecord,
        holder_info: HolderInfo,
        metadata: FundInfo<T>,
    }
    struct FundInfo<phantom T> has store{
        max_supply: u64,
        total_supply: u64,
        trader: address,
        name: String,
        desc: String,
    }
    struct InvestmentsRecord has store{
        invests: vector<ID>,
        cost_table: Table<ID, u64>,
        balance_bag: Bag,
        total_rewards: u64,
    }

    struct HolderInfo has store{
        holders: vector<address>, 
        holder_amount_table: Table<address, u64>,
    }
    
    struct FundCap<phantom T: drop> has key{
        id: UID,
        fund_id: ID,
    }

    struct FundShare<phantom T: drop> has key, store{
        id: UID,
        shares: u64,
        fund_id: ID,
        owner: address,
    }

    public fun new_fund<T: drop>(
        max_amount: u64,
        trader: address,
        commission_percentage: u8,
        name: String,
        desc: String,
        ctx: &mut TxContext,
    ): Fund<T>{
        
        let holder_info = HolderInfo{
            holders: vector::empty<address>(),
            holder_amount_table: table::new<address, u64>(ctx),
        };

        let metadata = FundInfo<T>{
            max_supply: max_amount,
            total_supply: 0,
            trader,
            name,
            desc,
        };

        let investments = InvestmentsRecord{
            invests: vector::empty<ID>(),
            cost_table: table::new<ID, u64>(ctx),
            balance_bag: bag::new(ctx),
            total_rewards: 0,
        };

        Fund<T>{
            id: object::new(ctx),
            balance: balance::zero<T>(),
            commission_percentage,
            investments,
            holder_info,
            metadata,
        }
    }

    public entry fun create_fund<T: drop>(
        max_amount: u64,
        trader: address,
        commission_percentage: u8,
        name: String,
        desc: String,
        ctx: &mut TxContext,
    ){
        let fund = new_fund<T>(
            max_amount,
            trader,
            commission_percentage,
            name,
            desc,
            ctx,
        );

        let fund_cap = FundCap<T>{
            id: object::new(ctx),
            fund_id: object::uid_to_inner(&fund.id),
        };

        transfer::public_share_object(fund);
        transfer::transfer(fund_cap,  trader);
    }

    public entry fun transfer_shares<T: drop>(
        fund: &mut Fund<T>,
        shares: FundShare<T>,
        to: address,
        ctx: &mut TxContext,
    ){
        let sender = tx_context::sender(ctx);
        let sender_amount = table::remove<address, u64>(&mut fund.holder_info.holder_amount_table, sender);

        let receiver_amount = 0;
        if (table::contains<address, u64>(&fund.holder_info.holder_amount_table, to)){
            receiver_amount = table::remove<address, u64>(&mut fund.holder_info.holder_amount_table, to);
        };
        
        sender_amount = sender_amount - shares.shares;
        receiver_amount = receiver_amount + shares.shares;

        if (sender_amount != 0){
            table::add<address, u64>(&mut fund.holder_info.holder_amount_table, sender, sender_amount);
        };
        table::add<address, u64>(&mut fund.holder_info.holder_amount_table, to ,receiver_amount);

        shares.owner = to;

        transfer::transfer(shares, to);
    }

    public entry fun mint <T: drop>(
        fund: &mut Fund<T>,
        amount: u64, 
        coins: &mut Coin<T>,
        ctx: &mut TxContext
    ){
        assert!(coin::value(coins) >= amount, EObjectCoinNotEnough);
        assert!(coin::value(coins) + balance::value<T>(&fund.balance) <= fund.metadata.max_supply, EOverMaxAmount);
        
        let sender = tx_context::sender(ctx); 
        let invest_coins = coin::split<T>(coins,amount, ctx);
        let invest_balance = coin::into_balance<T>(invest_coins);

        fund.metadata.total_supply = fund.metadata.total_supply + amount;

        if (table::contains(&fund.holder_info.holder_amount_table, sender)){
            let prievious_amount = table::remove(&mut fund.holder_info.holder_amount_table, sender);
            let update_amount = prievious_amount + amount;
            table::add(&mut fund.holder_info.holder_amount_table, sender, update_amount);
        }else{
            vector::push_back(&mut fund.holder_info.holders, sender);
            table::add(&mut fund.holder_info.holder_amount_table, sender, amount);
        };

        let shares = FundShare<T>{
            id: object::new(ctx),
            shares: balance::value<T>(&invest_balance),
            fund_id: object::uid_to_inner(&fund.id),
            owner: tx_context::sender(ctx),
        };
        
        balance::join<T>(&mut fund.balance, invest_balance);

        transfer::public_transfer(shares, tx_context::sender(ctx));
    }

    public entry fun invest< CoinA: drop , CoinB: drop>(
        fund_cap: &mut FundCap<CoinB>,
        fund: &mut Fund<CoinB>,
        config: &GlobalConfig,
        pool: &mut Pool<CoinA, CoinB>,
        amount: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
        ctx: &mut TxContext,
    ){
        assert!(balance::value<CoinB>(&fund.balance) >= amount, EBalanceNotEnough);
        assert!(object::uid_to_inner(&fund.id) == fund_cap.fund_id, EDifferentPuddle);

        
        let coin_b = &mut fund.balance;
        
        let invest_balance = invest::invest<CoinA, CoinB>(
            config,
            pool,
            coin_b,
            amount,
            sqrt_price_limit,
            clock,
            );
        let investment_target = *object::borrow_id(pool);
        
        if (vector::contains<ID>(&fund.investments.invests, &investment_target)){
            let previous_cost = table::remove(&mut fund.investments.cost_table, investment_target);
            let final_cost = previous_cost + amount;
            table::add<ID, u64>(&mut fund.investments.cost_table, investment_target, final_cost);

            balance::join<CoinA>(bag::borrow_mut<ID, Balance<CoinA>>(&mut fund.investments.balance_bag, investment_target), invest_balance);
        }else{
            vector::push_back<ID>(&mut fund.investments.invests, investment_target);
            table::add<ID, u64>(&mut fund.investments.cost_table, investment_target, amount);
            bag::add<ID, Balance<CoinA>>(&mut fund.investments.balance_bag, investment_target, invest_balance);
        } 
    }

    public entry fun arbitrage<CoinA: drop , CoinB: drop >(
        _fund_cap: &mut FundCap<CoinB>,
        fund: &mut Fund<CoinB>,
        config: &GlobalConfig,
        pool: &mut Pool<CoinA, CoinB>,
        amount: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
        ctx: &mut TxContext,
    ){
        
        let investment_target = *object::borrow_id(pool);
        let coin_a = bag::borrow_mut<ID, Balance<CoinA>>(&mut fund.investments.balance_bag, investment_target);
        assert!(amount <= balance::value<CoinA>(coin_a), EBalanceNotEnough);

        let receive_balance = invest::arbitrage<CoinA, CoinB>(
            config,
            pool,
            coin_a,
            amount,
            sqrt_price_limit,
            clock,
            );
        
        let cost = *table::borrow<ID, u64>(&mut fund.investments.cost_table, investment_target) * amount / balance::value<CoinA>(coin_a) ;
        if (cost < balance::value<CoinB>(&receive_balance)){
            let total_rewards = (balance::value<CoinB>(&receive_balance) - cost);
            let reward_for_trader_amounts =  total_rewards * (fund.commission_percentage as u64)* 10 / 1000;
            let rewards_for_team = total_rewards * 5 / 1000;
            let rewards_for_user_amount = total_rewards * (1000 - ((fund.commission_percentage as u64)*10) -5) / 1000;

            let trader_rewards = balance::split<CoinB>(&mut receive_balance, reward_for_trader_amounts);
            transfer::public_transfer(coin::from_balance<CoinB>(trader_rewards, ctx), fund.metadata.trader);


            
            let rewards = balance::split<CoinB>(&mut receive_balance, rewards_for_user_amount);
            give_out_bonus<CoinB>(fund, &mut rewards, ctx);

            if (balance::value<CoinB>(&rewards) == 0){
                balance::destroy_zero(rewards);
            }else{
                balance::join<CoinB>(&mut fund.balance, rewards);
            };
        
        };
        balance::join<CoinB>(&mut fund.balance, receive_balance);  
    }

    fun give_out_bonus<T:drop>(
        fund: &mut Fund<T>,
        total_rewards: &mut Balance<T>,
        ctx: &mut TxContext,
    ){
        let i: u64 = 0;
        let total_supply = fund.metadata.total_supply;

        while(i < vector::length(&fund.holder_info.holders)){
            let user_addr = *vector::borrow<address>(&mut fund.holder_info.holders, i);
            let user_shares_amount = table::remove<address, u64>(&mut fund.holder_info.holder_amount_table, user_addr);
            let user_rewards =  balance::value<T>(total_rewards) * user_shares_amount / total_supply;
            
            if (balance::value<T>(total_rewards) < user_rewards){
                let user_reward_balance = balance::split<T>(total_rewards, user_rewards);                
                let user_reward_coin = coin::from_balance<T>(user_reward_balance, ctx);
                transfer::public_transfer(user_reward_coin, user_addr);
                break
            }else{
                let user_reward_balance = balance::split<T>(total_rewards, user_rewards);
                let user_reward_coin = coin::from_balance<T>(user_reward_balance, ctx);
                transfer::public_transfer(user_reward_coin, user_addr);
                i = i + 1;
                continue
            }
            
        }
    }




}
    