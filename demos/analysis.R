# Welcome to the demo for shelly.nvim!
#
# This is a plugin for bringing a notebook-like experience to neovim with the
# integrated terminal
#
#   <C-Space> R <CR> <C-Space><C-Space>
#
# * Keybind to move cursor: <C-Space>
#     normal mode buf -> insert mode term -> normal mode term -> return to buf
#
# You can send the current line, current visual selection, or the current cell
# (lines of text that are surrounded with lines starting with the token `# %%`)
# to a toggleable terminal split
#
#   <C-c><C-c>
#
# * Keybind to send current cell to terminal, result saved to register
#

# %%

library(tidyverse)

data(crickets, package="modeldata")

# %%

# A couple of other features that set this apart from other toggleable
# terminals:
#
# * Safety check to prevent accidental execution in shell process
#
# * Optionally capture output to register for pasting output to buffer

# %%

library(tidymodels)
library(tidyverse)

data(crickets, package="modeldata")


# %% Let's make a seperate model for each species
split_by_species <- crickets |> group_nest(species)

split_by_species


# %% Create models
model_by_species <- split_by_species |>
    mutate(model = map(data, ~lm(rate ~ temp, data=.x)))

model_by_species


# %% Put the coefficients into a dang table
model_by_species |>
    mutate(coef = map(model,tidy)) |>
    select(species, coef) |>
    unnest(coef)

