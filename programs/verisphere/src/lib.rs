use anchor_lang::prelude::*;

//declare_id!("BjoPCPfAqaK9tfiyMGEecFi4HtA1LQEX6WdSWxL2ETyT");
declare_id!("Cf9Lf8pCfpV9iEajzLA84ZizQLK56N1r2PBfja5qegFY");

#[program]
pub mod verisphere {
    use super::*;

    pub fn initialize_post(_ctx: Context<InitializePost>, _stake: u64) -> Result<()> {
        // Placeholder: 1 VSP auto-stake fee
        Ok(())
    }

    pub fn stake(_ctx: Context<Stake>, _amount: u64, _agree: bool) -> Result<()> {
        // Placeholder: Add stake to agree or disagree
        Ok(())
    }
}

#[derive(Accounts)]
pub struct InitializePost<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Stake<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}
