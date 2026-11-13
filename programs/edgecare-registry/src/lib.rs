use anchor_lang::prelude::*;
// Local scaffold ID. Run anchor keys sync after generating a deployment keypair.
declare_id!("Fg6PaFpoGXkYsidMpWxTWqkZqkGmWcVJ9B8XhKfP7rD");

#[program]
pub mod edgecare_registry {
    use super::*;
    pub fn create_commitment(ctx: Context<CreateCommitment>, _referral_id: [u8; 16], hash: [u8; 32], verifier: Pubkey) -> Result<()> {
        let account = &mut ctx.accounts.commitment;
        account.commitment_hash = hash;
        account.verifier = verifier;
        account.spent = false;
        account.created_slot = Clock::get()?.slot;
        account.spent_slot = None;
        Ok(())
    }
    pub fn spend_commitment(ctx: Context<SpendCommitment>, _referral_id: [u8; 16]) -> Result<()> {
        mark_spent(&mut ctx.accounts.commitment, Clock::get()?.slot)
    }
}
fn mark_spent(account: &mut CommitmentAccount, slot: u64) -> Result<()> {
    require!(!account.spent, RegistryError::AlreadySpent);
    account.spent = true;
    account.spent_slot = Some(slot);
    Ok(())
}
#[derive(Accounts)]
#[instruction(referral_id: [u8; 16])]
pub struct CreateCommitment<'info> {
    #[account(init, payer = issuer, space = 8 + CommitmentAccount::INIT_SPACE,
        seeds = [b"commitment", referral_id.as_ref()], bump)]
    pub commitment: Account<'info, CommitmentAccount>,
    #[account(mut)]
    pub issuer: Signer<'info>,
    pub system_program: Program<'info, System>,
}
#[derive(Accounts)]
#[instruction(referral_id: [u8; 16])]
pub struct SpendCommitment<'info> {
    #[account(mut, seeds = [b"commitment", referral_id.as_ref()], bump, has_one = verifier)]
    pub commitment: Account<'info, CommitmentAccount>,
    pub verifier: Signer<'info>,
}
#[account]
#[derive(InitSpace)]
pub struct CommitmentAccount {
    pub commitment_hash: [u8; 32],
    pub verifier: Pubkey,
    pub spent: bool,
    pub created_slot: u64,
    pub spent_slot: Option<u64>,
}
#[error_code]
pub enum RegistryError {
    #[msg("This referral commitment has already been spent.")]
    AlreadySpent,
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn first_spend_wins() {
        let mut account = CommitmentAccount { commitment_hash: [1; 32], verifier: Pubkey::new_unique(), spent: false, created_slot: 1, spent_slot: None };
        assert!(mark_spent(&mut account, 2).is_ok());
        assert_eq!(account.spent_slot, Some(2));
        assert!(mark_spent(&mut account, 3).is_err());
        assert_eq!(account.spent_slot, Some(2));
    }
}
