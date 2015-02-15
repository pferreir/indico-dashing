class Dashing.TeamRepos extends Dashing.Widget

  ready: ->


  onData: (data) ->
    sortedItems = new Batman.Set
    sortedItems.add.apply(sortedItems, data.heads)
    @set 'heads', sortedItems
    node = @node

    setTimeout ->
      $(node).find('ul.head-list li').each (i, elem) ->
        $elem = $(elem)
        $parent = $elem.offsetParent()
        if $elem.position().top + $elem.height() + 20 > $parent.height()
          $elem.hide()
    , 100
