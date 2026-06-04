<script lang="ts">
	import { ScrollText, Check } from '@lucide/svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import * as Tooltip from '$lib/components/ui/tooltip';
	import { CONSTITUTIONS } from '$lib/data/constitutions-data';
	import { chatStore } from '$lib/stores/chat.svelte';
	import { conversationsStore } from '$lib/stores/conversations.svelte';

	let open = $state(false);
	let activeConstitutionName = $state<string | null>(null);

	// Reset selection when the conversation changes
	$effect(() => {
		const _conv = conversationsStore.activeConversation?.id;
		activeConstitutionName = null;
	});

	async function select(name: string, content: string) {
		if (activeConstitutionName === name) {
			activeConstitutionName = null;
		} else {
			activeConstitutionName = name;
			await chatStore.setConstitution(content);
		}
		open = false;
	}
</script>

<DropdownMenu.Root bind:open>
	<Tooltip.Root>
		<Tooltip.Trigger>
			<DropdownMenu.Trigger
				class={[
					'flex h-6 w-6 cursor-pointer items-center justify-center rounded-full p-0 transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2',
					activeConstitutionName
						? 'bg-emerald-400/10 hover:bg-emerald-400/20'
						: 'bg-muted hover:bg-muted/80'
				]}
				aria-label="Select constitution"
			>
				<ScrollText
					class={[
						'h-3 w-3',
						activeConstitutionName ? 'text-emerald-400' : 'text-muted-foreground'
					]}
				/>
			</DropdownMenu.Trigger>
		</Tooltip.Trigger>

		<Tooltip.Content>
			<p>{activeConstitutionName ? `Constitution: ${activeConstitutionName}` : 'Select Constitution'}</p>
		</Tooltip.Content>
	</Tooltip.Root>

	<DropdownMenu.Content
		align="start"
		class="w-72 rounded-xl bg-popover p-3 text-popover-foreground shadow-md outline-none"
	>
		<div class="mb-2 px-2.5 text-sm font-medium">Constitutions</div>

		{#each CONSTITUTIONS as constitution (constitution.name)}
			<button
				type="button"
				class="flex w-full cursor-pointer items-start gap-2 rounded-lg px-2.5 py-2 text-left text-sm transition-colors hover:bg-accent"
				class:bg-accent={activeConstitutionName === constitution.name}
				onclick={() => select(constitution.name, constitution.content)}
			>
				{#if activeConstitutionName === constitution.name}
					<Check class="mt-0.5 h-4 w-4 shrink-0 text-emerald-400" />
				{:else}
					<div class="mt-0.5 h-4 w-4 shrink-0"></div>
				{/if}

				<div class="min-w-0 flex-1">
					<div class="font-medium">{constitution.name}</div>
					<div class="mt-0.5 truncate text-[11px] text-muted-foreground">
						{constitution.description}
					</div>
				</div>
			</button>
		{/each}
	</DropdownMenu.Content>
</DropdownMenu.Root>
