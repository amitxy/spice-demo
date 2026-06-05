<script lang="ts">
	import { Check, ChevronDown } from '@lucide/svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import { CONSTITUTIONS } from '$lib/data/constitutions-data';
	import { chatStore } from '$lib/stores/chat.svelte';
	import { conversationsStore } from '$lib/stores/conversations.svelte';

	let open = $state(false);
	let activeConstitutionName = $state<string | null>(null);
	let trackedConvId = $state<string | undefined>(undefined);

	// Reset only when switching to a different conversation, not when the
	// current conversation gets its ID assigned after the first message.
	$effect(() => {
		const convId = conversationsStore.activeConversation?.id;
		if (convId !== trackedConvId) {
			if (trackedConvId !== undefined) {
				activeConstitutionName = null;
			}
			trackedConvId = convId;
		}
	});

	async function select(name: string, content: string) {
		if (activeConstitutionName === name) {
			activeConstitutionName = null;
		} else {
			activeConstitutionName = name;
			await chatStore.setConstitution(name, content);
		}
		open = false;
	}
</script>

<DropdownMenu.Root bind:open>
	<DropdownMenu.Trigger
		class={[
			'flex h-8 cursor-pointer items-center gap-1.5 rounded-full px-3 text-xs font-medium transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2',
			activeConstitutionName
				? 'bg-emerald-400/15 text-emerald-400 hover:bg-emerald-400/25'
				: 'bg-muted text-muted-foreground hover:bg-muted/80 hover:text-foreground'
		]}
		aria-label="Select personality"
	>
		<span>{activeConstitutionName ?? 'Choose personality'}</span>
		<ChevronDown class="h-3 w-3 shrink-0 opacity-70" />
	</DropdownMenu.Trigger>

	<DropdownMenu.Content
		align="start"
		class="w-72 rounded-xl bg-popover p-3 text-popover-foreground shadow-md outline-none"
	>
		<div class="mb-2 px-2.5 text-sm font-medium">Personalities</div>

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
